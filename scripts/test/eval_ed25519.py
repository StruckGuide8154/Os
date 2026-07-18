#!/usr/bin/env python3
# Track-2 Ed25519 verifier evaluation: executes the REAL in-kernel GHL
# sources (ed25519_check.ghl + envelope_reader.ghl + policy kernels) against
# RFC 8032 test vectors and real signed envelopes.
#
# Like eval_envelope.py this goes through the production compiler's own
# lexer/parser (gritc.lex / gritc.parse), so the logic under test is exactly
# what ships. Unlike eval_envelope.py the AST is TRANSPILED to Python
# functions instead of tree-walked - field arithmetic runs ~50x faster, which
# is what makes whole Ed25519 verifications testable on the host. The
# transpiler covers only the integer subset these modules use and hard-errors
# on anything else, so it can never silently skip logic.
#
# Suite:
#   1. pubkey-drift guard: the GHL ed_role_pubs table must equal the host
#      derivation (scripts/build/ed25519_host.py dev seeds).
#   2. SHA-512 differential: GHL ed_sha512_* vs hashlib on assorted lengths.
#   3. RFC 8032 vectors (TEST 1/2/3) + tamper negatives through the GHL
#      ed25519_verify.
#   4. Signed envelopes through the GHL envelope_verify_signed: quorum-signed
#      accept, tampered signature, placeholder sigs, under-quorum signing,
#      and a structural reject (bad magic) keeping its precise reason code.

import hashlib
import os
import struct
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
COMPILER_DIR = os.path.join(ROOT, 'src', 'user', 'grithl', 'compiler')
BUILD_DIR = os.path.join(ROOT, 'scripts', 'build')
MODULES = [
    os.path.join(ROOT, 'src', 'tools', 'security', 'signed_envelope.ghl'),
    os.path.join(ROOT, 'src', 'tools', 'security', 'signed_artifact_check.ghl'),
    os.path.join(ROOT, 'src', 'tools', 'security', 'threshold_check.ghl'),
    os.path.join(ROOT, 'src', 'kernel', 'grithlk', 'envelope_reader.ghl'),
    os.path.join(ROOT, 'src', 'kernel', 'grithlk', 'ed25519_check.ghl'),
    # Track 2 call-site binding: the admission gate + the SHA-256 it uses
    # + the persistent anti-rollback floors the gate's verifier context reads.
    os.path.join(ROOT, 'src', 'kernel', 'grithlk', 'crypto.ghl'),
    os.path.join(ROOT, 'src', 'kernel', 'grithlk', 'floor_store.ghl'),
    os.path.join(ROOT, 'src', 'kernel', 'grithlk', 'envelope_gate.ghl'),
]

sys.path.insert(0, COMPILER_DIR)
sys.path.insert(0, BUILD_DIR)
import gritc          # noqa: E402  production GHL compiler - source of truth
import ed25519_host  # noqa: E402  independent host reference + dev keys


class TranspileError(Exception):
    pass


class PanicCalled(Exception):
    """Raised when transpiled code reaches kernel_panic_canary (fail-closed
    path) - tests assert this fires for rejected boot artifacts."""
    pass


# Extern fns that are pure I/O / fatal sinks on the kernel side. Serial output
# is a no-op on the host; the panic sink raises so the fail-closed control
# flow stays observable.
STUB_NOOP_FNS = {'serial_puts', 'serial_crlf', 'svg_dump_putc',
                 'ser_print_hex64',
                 # Host ATA / block: "success" (0) with the sector buffer left
                 # as-is, so floor_persist -> floor_store_load round-trips through
                 # floor_store's own floor_buf encode/decode/checksum path.
                 # blk_write_sectors is floor_store's storage-class-routed writer
                 # (NVMe/USB write-back path); same host no-op as the ATA pair.
                 'ata_read_sectors', 'ata_write_sectors', 'blk_write_sectors',
                 # floor_store storage-class selector: 0 (= ramdisk/default) is
                 # the right host answer; the ed25519 tests don't depend on the
                 # write-back routing it chooses.
                 'ramdisk_storage_class',
                 # envelope_gate's real per-machine device-id derivation
                 # (gate_device_id_init) reads CPUID leaves. In the host eval
                 # there is no CPU to query and, by the module's own contract,
                 # gate_device_id() answers the wildcard until init runs - the
                 # eval drives device_id through its verifier context directly,
                 # so these only need to TRANSPILE, never execute. No-op = 0.
                 'cpuid_eax', 'cpuid_ebx', 'cpuid_ecx', 'cpuid_edx',
                 # Kernel spinlocks (workqueue.ghl / bounded_lock.ghl). The host
                 # eval is single-threaded, so acquire/release are no-ops; crypto
                 # serializes its scratch state behind wq_lock on real hardware.
                 'wq_lock', 'wq_unlock'}
STUB_PANIC_FNS = {'kernel_panic_canary'}


CMP_OPS = {'==': '==', '!=': '!=', '<': '<', '>': '>', '<=': '<=', '>=': '>='}
ARITH_OPS = {'&', '|', '^', '+', '-', '*', '<<', '>>', '/', '%'}


class Unit:
    """All modules transpiled into one Python namespace over one flat memory
    image (mirroring the single NASM unit kernel_build.asm assembles)."""

    DATA_BASE = 0x800000   # data segment, above any test blob placement

    def __init__(self, paths):
        self.consts, self.fns, self.data = {}, {}, {}
        decls_all = []
        for path in paths:
            with open(path, 'r', encoding='utf-8') as fh:
                src = fh.read()
            decls_all.extend(gritc.parse(gritc.lex(src, path), path))
        for d in decls_all:
            k = d.get('k')
            if k == 'const':
                if d.get('symbolic'):
                    continue
                if d['name'] in self.consts and self.consts[d['name']] != d['val']:
                    raise TranspileError('const %s disagrees across modules' % d['name'])
                self.consts[d['name']] = d['val']
            elif k == 'fn':
                if d.get('regparams') or d.get('naked'):
                    raise TranspileError('fn %s is register-param/naked' % d['name'])
                if d['name'] in self.fns:
                    raise TranspileError('duplicate fn %s' % d['name'])
                self.fns[d['name']] = d
            elif k == 'data':
                if d['name'] in self.data:
                    raise TranspileError('duplicate data %s' % d['name'])
                self.data[d['name']] = d
        self._layout_data()
        self._compile()

    # ---- data segment ------------------------------------------------------

    def _factor(self, f):
        kind, v = f[0], f[1]
        if kind == 'num':
            return v
        if v in self.consts:
            return self.consts[v]
        raise TranspileError('data size factor %r unresolved' % (v,))

    def _layout_data(self):
        self.data_addr, self.mem = {}, bytearray(self.DATA_BASE)
        for name, d in self.data.items():
            addr = len(self.mem)
            if 'strval' in d:
                blob = d['strval'].encode('latin-1') + b'\x00'
            else:
                count = 1
                for f in d['factors']:
                    count *= self._factor(f)
                width = d.get('width', 1)
                init = d.get('init')
                if init['k'] == 'list':
                    vals = []
                    for v in init['vals']:
                        if isinstance(v, tuple):
                            base = self.consts[v[1]]
                            vals.append(-base if v[2] else base)
                        else:
                            vals.append(v)
                    if len(vals) > count:
                        raise TranspileError('data %s: %d inits > count %d'
                                             % (name, len(vals), count))
                    vals += [0] * (count - len(vals))
                elif init['k'] == 'int':
                    vals = [init['val']] * count
                elif init['k'] == 'ident':
                    vals = [self.consts[init['name']]] * count
                else:
                    raise TranspileError('data %s: bad init' % name)
                blob = b''.join((v & ((1 << (8 * width)) - 1)).to_bytes(width, 'little')
                                for v in vals)
            self.data_addr[name] = addr
            self.mem += blob

    # ---- memory builtins ----------------------------------------------------

    def _ck(self, addr, size):
        if addr < 0 or addr + size > len(self.mem):
            raise TranspileError('out-of-memory access at 0x%x size %d' % (addr, size))

    def lb(self, a):
        self._ck(a, 1)
        return self.mem[a]

    def lw(self, a):
        self._ck(a, 4)
        return struct.unpack_from('<i', self.mem, a)[0]   # movsxd

    def lq(self, a):
        self._ck(a, 8)
        return struct.unpack_from('<Q', self.mem, a)[0]

    def sb(self, a, v):
        self._ck(a, 1)
        self.mem[a] = v & 0xFF
        return 0

    def sw(self, a, v):
        self._ck(a, 4)
        struct.pack_into('<I', self.mem, a, v & 0xFFFFFFFF)
        return 0

    def sq(self, a, v):
        self._ck(a, 8)
        struct.pack_into('<Q', self.mem, a, v & 0xFFFFFFFFFFFFFFFF)
        return 0

    # ---- transpiler ----------------------------------------------------------

    def _expr(self, e):
        k = e['k']
        if k == 'int':
            return repr(e['val'])
        if k == 'ident':
            nm = e['name']
            if nm in self.consts:
                return repr(self.consts[nm])
            return nm                      # param / local
        if k == 'addr':
            if e['name'] not in self.data_addr:
                # Extern kernel data symbol: back it with a zeroed host block
                # so modules that reference cross-unit data (e.g. the gate's
                # app_integrity_table) transpile; tests fill the bytes in.
                self.data_addr[e['name']] = len(self.mem)
                self.mem += bytearray(8192)
            return repr(self.data_addr[e['name']])
        if k == 'neg':
            return '(-(%s))' % self._expr(e['expr'])
        if k == 'not':
            return '(0 if (%s)!=0 else 1)' % self._expr(e['expr'])
        if k == 'call':
            args = ', '.join(self._expr(a) for a in e['args'])
            nm = e['name']
            if nm in ('lb', 'lw', 'lq', 'sb', 'sw', 'sq', 'ror32', 'mulhi'):
                return '_U.%s(%s)' % (nm, args)
            if nm not in self.fns:
                if nm in STUB_NOOP_FNS:
                    return '_U.stub_noop(%s)' % args
                if nm in STUB_PANIC_FNS:
                    return '_U.stub_panic(%s)' % args
                raise TranspileError('call to unknown fn %s' % nm)
            return '%s(%s)' % (nm, args)
        if k == 'bin':
            op, a, b = e['op'], self._expr(e['lhs']), self._expr(e['rhs'])
            if op in CMP_OPS:
                return '(1 if (%s) %s (%s) else 0)' % (a, CMP_OPS[op], b)
            if op == '&&':
                return '(1 if ((%s)!=0 and (%s)!=0) else 0)' % (a, b)
            if op == '||':
                return '(1 if ((%s)!=0 or (%s)!=0) else 0)' % (a, b)
            if op == '/':
                return '((%s) // (%s))' % (a, b)
            if op in ARITH_OPS:
                return '((%s) %s (%s))' % (a, op, b)
        raise TranspileError('unsupported expression kind %r' % k)

    def _stmt(self, st, out, ind):
        pad = '    ' * ind
        k = st['k']
        if k == 'let' :
            out.append('%s%s = %s' % (pad, st['name'], self._expr(st['expr'])))
        elif k == 'assign':
            if st['lhs'].get('k') != 'ident':
                raise TranspileError('only simple-variable assignment supported')
            out.append('%s%s = %s' % (pad, st['lhs']['name'], self._expr(st['rhs'])))
        elif k == 'return':
            if st['expr'] is None:
                out.append('%sreturn 0' % pad)
            else:
                out.append('%sreturn %s' % (pad, self._expr(st['expr'])))
        elif k == 'if':
            out.append('%sif (%s) != 0:' % (pad, self._expr(st['cond'])))
            self._block(st['then'], out, ind + 1)
            if st['els'] is not None:
                out.append('%selse:' % pad)
                self._block(st['els'], out, ind + 1)
        elif k == 'while':
            out.append('%swhile (%s) != 0:' % (pad, self._expr(st['cond'])))
            self._block(st['body'], out, ind + 1)
        elif k == 'break':
            out.append('%sbreak' % pad)
        elif k == 'continue':
            out.append('%scontinue' % pad)
        elif k == 'exprstmt':
            out.append('%s%s' % (pad, self._expr(st['expr'])))
        elif k == 'cfg':
            # Host evaluation: no build defines set. cfg "X" takes the else
            # arm, cfg !"X" takes the body (matches the default debug build
            # for everything the gate suite exercises).
            taken = st['body'] if st['neg'] else (st['els'] or [])
            for inner in taken:
                self._stmt(inner, out, ind)
        elif k == 'regcall':
            # Register-exact call (serial/debug helpers). Evaluate args for
            # side-effect parity, dispatch to the host stub.
            nm = st['target']
            if nm not in (STUB_NOOP_FNS | STUB_PANIC_FNS):
                raise TranspileError('regcall to unknown fn %s' % nm)
            fnname = 'stub_panic' if nm in STUB_PANIC_FNS else 'stub_noop'
            args = ', '.join(self._expr(a) for _r, a in st['regargs'])
            out.append('%s_U.%s(%s)' % (pad, fnname, args))
        else:
            raise TranspileError('unsupported statement kind %r' % k)

    def _block(self, stmts, out, ind):
        if not stmts:
            out.append('    ' * ind + 'pass')
            return
        for st in stmts:
            self._stmt(st, out, ind)

    def _compile(self):
        lines = []
        for name, fn in self.fns.items():
            lines.append('def %s(%s):' % (name, ', '.join(fn['params'])))
            self._block(fn['body'], lines, 1)
            lines.append('')
        src = '\n'.join(lines)
        self.ns = {'_U': self}
        exec(compile(src, '<ghl-transpiled>', 'exec'), self.ns)

    def call(self, name, *args):
        return self.ns[name](*args)

    def ror32(self, x, n):
        x &= 0xFFFFFFFF
        n &= 31
        return ((x >> n) | (x << (32 - n))) & 0xFFFFFFFF

    def mulhi(self, a, b):
        # High 64 bits of the unsigned 64x64->128 product (mirrors `mul`).
        return ((a & 0xFFFFFFFFFFFFFFFF) * (b & 0xFFFFFFFFFFFFFFFF)) >> 64

    # ---- extern stubs ---------------------------------------------------------

    def stub_noop(self, *args):
        return 0

    def stub_panic(self, *args):
        raise PanicCalled('kernel_panic_canary%r' % (args,))

    # ---- test-blob placement -------------------------------------------------

    def place(self, blob):
        """Append a blob at the end of memory; returns its base address."""
        addr = len(self.mem)
        self.mem += blob
        return addr


# ---------------------------------------------------------------------------

FAILURES = []


def check(label, ok, detail=''):
    print('[ed25519] %-44s [%s]%s' % (label, 'ok' if ok else 'FAIL',
                                      (' ' + detail if detail and not ok else '')))
    if not ok:
        FAILURES.append(label + (': ' + detail if detail else ''))


def ghl_verify(u, pub, msg, sig):
    pp = u.place(pub)
    mp = u.place(msg) if msg else u.place(b'\x00')   # non-zero ptr for len 0
    sp = u.place(sig)
    return u.call('ed25519_verify', pp, mp, len(msg), sp)


def main():
    u = Unit(MODULES)
    print('[ed25519] transpiled %d fns, %d data symbols, %d consts '
          '(production gritc frontend)' % (len(u.fns), len(u.data), len(u.consts)))

    # 1. pubkey-drift guard
    tbl = u.data_addr['ed_role_pubs']
    baked = bytes(u.mem[tbl:tbl + 192])
    derived = b''.join(ed25519_host.dev_role_public(r) for r in range(1, 7))
    check('role pubkey table matches host derivation', baked == derived)

    # 2. SHA-512 differential vs hashlib
    for msg in (b'', b'abc', b'a' * 111, b'a' * 112, b'a' * 127, b'a' * 128,
                bytes(range(256)) * 3):
        mp = u.place(msg if msg else b'\x00')
        u.call('ed_sha512_init')
        u.call('ed_sha512_update', mp, len(msg))
        out = u.place(b'\x00' * 64)
        u.call('ed_sha512_final', out)
        got = bytes(u.mem[out:out + 64])
        check('sha512(len=%d) matches hashlib' % len(msg),
              got == hashlib.sha512(msg).digest())

    # 3. RFC 8032 vectors
    vec = [
        ('9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60', b''),
        ('4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb', b'\x72'),
        ('c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7',
         b'\xaf\x82'),
    ]
    for i, (skh, msg) in enumerate(vec):
        sk = bytes.fromhex(skh)
        pub = ed25519_host.public_key(sk)
        sig = ed25519_host.sign(sk, msg)
        check('RFC 8032 TEST %d verifies' % (i + 1),
              ghl_verify(u, pub, msg, sig) == 1)
    # negatives: tampered sig / msg / pubkey, non-canonical S
    sk = bytes.fromhex(vec[2][0])
    pub, msg = ed25519_host.public_key(sk), vec[2][1]
    sig = ed25519_host.sign(sk, msg)
    bad = bytearray(sig); bad[5] ^= 1
    check('tampered signature rejected', ghl_verify(u, pub, msg, bytes(bad)) == 0)
    check('tampered message rejected', ghl_verify(u, pub, msg + b'!', sig) == 0)
    badp = bytearray(pub); badp[3] ^= 1
    check('wrong public key rejected', ghl_verify(u, bytes(badp), msg, sig) == 0)
    bads = bytearray(sig)
    s = int.from_bytes(sig[32:], 'little') + ed25519_host.L
    bads[32:] = s.to_bytes(32, 'little')
    check('non-canonical S (S+L) rejected', ghl_verify(u, pub, msg, bytes(bads)) == 0)

    # 4. signed envelopes through envelope_verify_signed
    import write_envelope as we
    payload = b'Grit signed-envelope crypto test payload'
    kw = dict(payload=payload, kind=5, domain=5, role=4,
              device_id=0x11, device_class=0,
              not_before=500, not_after=2000,
              version=5, rollback=3, epoch=2,
              min_cosigners=2, allowed_mask=0x3F, required_mask=0x04,
              sig_count=2,
              provenance_hash=b'\xAB' * 32, policy_dep_hash=b'\xCD' * 32)
    ctx = (1000, 0x11, 0x22, 5, 3, 2)   # now, dev id, dev class, ver, ctr, epoch

    def run_signed(blob):
        base = u.place(blob)
        digest = u.place(hashlib.sha256(payload).digest())
        return u.call('envelope_verify_signed', base, len(blob), digest, *ctx)

    ok_env = we.build_envelope(**kw)                          # auto quorum sign
    check('quorum-signed envelope accepted (ENVR_OK)', run_signed(ok_env) == 0,
          'rc=%d' % run_signed(ok_env))

    tampered = bytearray(ok_env); tampered[-20] ^= 0xFF       # inside sig block
    rc = run_signed(bytes(tampered))
    check('tampered signature block -> ENVR_ERR_SIGCRYPTO', rc == 22, 'rc=%d' % rc)

    placeholder = we.build_envelope(sign_roles=[], **kw)      # 0x5A slots
    rc = run_signed(placeholder)
    check('placeholder (unsigned) sigs -> ENVR_ERR_SIGCRYPTO', rc == 22, 'rc=%d' % rc)

    under = we.build_envelope(sign_roles=[3], **kw)           # 1 sig < min 2
    rc = run_signed(under)
    check('under-quorum signing -> ENVR_ERR_SIGCRYPTO', rc == 22, 'rc=%d' % rc)

    wrongrole = we.build_envelope(sign_roles=[1, 2], **kw)    # required POLICY missing
    rc = run_signed(wrongrole)
    check('required role unsigned -> ENVR_ERR_SIGCRYPTO', rc == 22, 'rc=%d' % rc)

    badmagic = b'EVIL' + ok_env[4:]
    rc = run_signed(badmagic)
    check('structural reject keeps reason (ENVR_ERR_MAGIC)', rc == 2, 'rc=%d' % rc)

    # 5. artifact admission gate (envelope_gate.ghl): the boot/update call-site
    # binding + the verified-artifact hash cache. The gate computes the payload
    # SHA-256 itself (crypto.ghl, the real kernel implementation) and pins its
    # own verifier context (device_id=1; floors from floor_store.ghl, build
    # default 1), so envelopes here match the write_envelope.py defaults.
    gkw = dict(kind=5, domain=5, role=4, device_id=1, device_class=0,
               not_before=0, not_after=0xFFFFFFFF,
               version=1, rollback=1, epoch=1,
               min_cosigners=2, allowed_mask=0x3F, required_mask=0x04,
               sig_count=2, provenance_hash=b'\xAB' * 32,
               policy_dep_hash=b'\xCD' * 32)
    ART_APP, ART_UPDATE = 5, 8

    def stats():
        return (u.lw(u.data_addr['gate_stat_hits']),
                u.lw(u.data_addr['gate_stat_checks']))

    def admit(blob, expected_type):
        return u.call('artifact_gate_admit', u.place(blob), len(blob),
                      expected_type)

    app_env = we.build_envelope(payload=b'gate cache test payload', **gkw)
    rc = admit(app_env, ART_APP)
    h1, c1 = stats()
    check('gate admits quorum-signed app envelope', rc == 0, 'rc=%d' % rc)
    check('first admit is a full Ed25519 check', (h1, c1) == (0, 1),
          'hits=%d checks=%d' % (h1, c1))
    rc = admit(app_env, ART_APP)
    h2, c2 = stats()
    check('re-admit still accepts', rc == 0, 'rc=%d' % rc)
    check('re-admit hits the hash cache (no new Ed25519)',
          (h2, c2) == (1, 1), 'hits=%d checks=%d' % (h2, c2))

    tampered = bytearray(app_env)
    tampered[-10] ^= 0xFF                       # sig block bit flip
    rc = admit(bytes(tampered), ART_APP)
    h3, c3 = stats()
    check('tampered bytes miss the cache and reject (SIGCRYPTO)',
          rc == 22 and (h3, c3) == (1, 2), 'rc=%d hits=%d checks=%d' % (rc, h3, c3))

    upd_kw = dict(gkw)
    upd_kw.update(kind=8, domain=1, role=6, min_cosigners=3,
                  required_mask=0x0B, sig_count=3)
    upd_env = we.build_envelope(payload=b'staged update artifact', **upd_kw)
    rc = admit(upd_env, ART_UPDATE)
    check('gate admits quorum-signed update envelope', rc == 0, 'rc=%d' % rc)
    rc = admit(upd_env, ART_APP)
    check('validly signed WRONG-class envelope refused at the call site '
          '(GATE_ERR_CALLER_TYPE)', rc == 23, 'rc=%d' % rc)

    rejected = we.build_envelope(payload=b'unsigned input', sign_roles=[],
                                 **gkw)
    rc = admit(rejected, ART_APP)
    check('placeholder-signed input rejected at the gate', rc == 22,
          'rc=%d' % rc)
    rc2 = admit(rejected, ART_APP)
    _h, c_last = stats()
    check('rejected envelopes are never cached', rc2 == 22, 'rc=%d' % rc2)

    # 6. boot-chain / update-path call sites end to end. VBE_INFO (0x9000)
    # is inside the interpreter's zeroed low region, so the loader handoff is
    # emulated by writing the (base,size) pairs the UEFI loader publishes.
    VBE_SYSSIG, VBE_KUPDATE = 0x9080, 0x9090
    tbl_addr = u.data_addr['app_integrity_table']
    table_bytes = bytes(range(256)) * 5 + bytes(180)   # 1460-byte stand-in
    u.mem[tbl_addr:tbl_addr + 1460] = table_bytes
    sys_env = we.build_envelope(payload=table_bytes, **gkw)
    sb_addr = u.place(sys_env)
    u.sq(VBE_SYSSIG, sb_addr)
    u.sq(VBE_SYSSIG + 8, len(sys_env))
    try:
        u.call('syssig_verify_boot')
        check('syssig_verify_boot accepts the signed integrity table', True)
    except PanicCalled as e:
        check('syssig_verify_boot accepts the signed integrity table', False,
              str(e))

    u.mem[tbl_addr] ^= 0x01                     # live table != signed payload
    try:
        u.call('syssig_verify_boot')
        check('table/payload mismatch panics (fail closed)', False)
    except PanicCalled:
        check('table/payload mismatch panics (fail closed)', True)
    u.mem[tbl_addr] ^= 0x01

    u.sq(VBE_SYSSIG, 0)
    u.sq(VBE_SYSSIG + 8, 0)
    try:
        u.call('syssig_verify_boot')
        check('missing SYSSIG.ENV panics (no unsigned fallback)', False)
    except PanicCalled:
        check('missing SYSSIG.ENV panics (no unsigned fallback)', True)

    u.sq(VBE_KUPDATE, 0)
    u.sq(VBE_KUPDATE + 8, 0)
    u.call('boot_update_check')
    check('no staged update -> none latched',
          u.lb(u.data_addr['kupdate_present']) == 0)
    ub_addr = u.place(upd_env)
    u.sq(VBE_KUPDATE, ub_addr)
    u.sq(VBE_KUPDATE + 8, len(upd_env))
    u.call('boot_update_check')
    check('staged signed update accepted through the gate',
          u.lb(u.data_addr['kupdate_present']) == 1 and
          u.lw(u.data_addr['kupdate_rc']) == 0,
          'rc=%d' % u.lw(u.data_addr['kupdate_rc']))
    bad_upd = bytearray(upd_env)
    bad_upd[len(upd_env) - 70] ^= 0x80
    bu_addr = u.place(bytes(bad_upd))
    u.sq(VBE_KUPDATE, bu_addr)
    u.sq(VBE_KUPDATE + 8, len(bad_upd))
    u.call('boot_update_check')
    check('tampered staged update rejected with reason',
          u.lw(u.data_addr['kupdate_rc']) != 0,
          'rc=%d' % u.lw(u.data_addr['kupdate_rc']))

    # 7. "No single stolen key authorizes any critical action" - the four
    # named Track-2 scenarios, as executable negatives against the REAL
    # verifier with the gate's verifier context. Each envelope is otherwise
    # fully valid; only the signature set is what a single compromised key
    # (or one compromised infrastructure host) could produce.
    def vsig(blob, payload):
        base = u.place(blob)
        dg = u.place(hashlib.sha256(payload).digest())
        return u.call('envelope_verify_signed', base, len(blob), dg,
                      1, 1, 0, 1, 1, 1)

    kern_kw = dict(gkw)
    kern_kw.update(kind=2, domain=2, role=2, min_cosigners=3,
                   required_mask=0x03, sig_count=3)
    pk = b'kernel artifact'
    rc = vsig(we.build_envelope(payload=pk, sign_roles=[2], **kern_kw), pk)
    check('one stolen KERNEL key cannot authorize a kernel', rc == 22, 'rc=%d' % rc)
    rc = vsig(we.build_envelope(payload=pk, sign_roles=[2, 2, 2], **kern_kw), pk)
    check('one key repeated 3x still counts as one role', rc == 22, 'rc=%d' % rc)

    pa = b'app release'
    rc = vsig(we.build_envelope(payload=pa, sign_roles=[2], **gkw), pa)
    check('one build-server key cannot release an app', rc == 22, 'rc=%d' % rc)
    forged = dict(gkw)
    forged.update(min_cosigners=1, required_mask=0x00)
    rc = vsig(we.build_envelope(payload=pa, sign_roles=[2], **forged), pa)
    check('declaring min_count=1 is rejected at the class floor (QUORUM)',
          rc == 21, 'rc=%d' % rc)

    pu = b'shipped update'
    rc = vsig(we.build_envelope(payload=pu, sign_roles=[4], **upd_kw), pu)
    check('one update-server key cannot ship an update', rc == 22, 'rc=%d' % rc)

    rec_kw = dict(gkw)
    rec_kw.update(kind=9, domain=7, role=7, min_cosigners=3,
                  required_mask=0x13, sig_count=3)
    pr = b'reset trust anchors'
    rc = vsig(we.build_envelope(payload=pr, sign_roles=[5], **rec_kw), pr)
    check('one recovery key cannot reset trust anchors', rc == 22, 'rc=%d' % rc)

    # 8. Quorum-change tracking path (quorum_change_admit + the active-quorum
    # ratchet in artifact_gate_admit): a change must match the ACTIVE rule,
    # be a valid non-downgrade, and be approved by BOTH the old and the new
    # quorum; an accepted change binds every later admission.
    ART_POLICY = 6

    def qch_payload(kind, old, new):
        return b'QCH1' + struct.pack('<7H', kind, *old, *new)

    def qch_env(payload, sign_roles, kind=ART_POLICY):
        pol_kw = dict(gkw)
        pol_kw.update(kind=kind, domain=6 if kind == ART_POLICY else gkw['domain'],
                      role=5 if kind == ART_POLICY else gkw['role'])
        return we.build_envelope(payload=payload, sign_roles=sign_roles, **pol_kw)

    def qch_admit(blob):
        return u.call('quorum_change_admit', u.place(blob), len(blob))

    OLD5, NEW5 = (2, 0x3F, 0x04), (3, 0x3F, 0x04)
    check('active quorum starts at the build-time class floor',
          u.call('gate_quorum_active_min', 5) == 2 and
          u.call('gate_quorum_active_required', 5) == 0x04)

    rc = qch_admit(qch_env(qch_payload(5, OLD5, NEW5), [2, 3]))
    check('change approved by old quorum ONLY is refused (APPROVAL)',
          rc == 27 and u.call('gate_quorum_active_min', 5) == 2, 'rc=%d' % rc)

    rc = qch_admit(qch_env(qch_payload(5, (9, 0x3F, 0x04), NEW5), [1, 2, 3]))
    check('change declaring a stale old rule is refused (STATE)',
          rc == 25, 'rc=%d' % rc)

    rc = qch_admit(qch_env(qch_payload(5, OLD5, NEW5), [1, 2, 3], kind=5))
    check('quorum change in a non-policy envelope refused (CALLER_TYPE)',
          rc == 23, 'rc=%d' % rc)

    good_change = qch_env(qch_payload(5, OLD5, NEW5), [1, 2, 3])
    rc = qch_admit(good_change)
    check('dual-quorum-approved change accepted and ratchets',
          rc == 0 and u.call('gate_quorum_active_min', 5) == 3, 'rc=%d' % rc)

    rc = admit(app_env, ART_APP)
    check('previously-admissible app envelope (declared min 2) now refused '
          'by the ratchet', rc == 28, 'rc=%d' % rc)

    strict_kw = dict(gkw)
    strict_kw.update(min_cosigners=3, sig_count=3)
    rc = admit(we.build_envelope(payload=b'app at new quorum', **strict_kw),
               ART_APP)
    check('app envelope declared+signed at the ratcheted quorum admitted',
          rc == 0, 'rc=%d' % rc)

    rc = qch_admit(good_change)
    check('replaying the same change against superseded state refused (STATE)',
          rc == 25, 'rc=%d' % rc)

    rc = qch_admit(qch_env(qch_payload(5, NEW5, OLD5), [1, 2, 3]))
    check('quorum downgrade refused (RULE)', rc == 26, 'rc=%d' % rc)

    # boot_quorum_check call site: absent file -> none; staged change -> latch.
    VBE_KQUORUM = 0x90A0
    u.sq(VBE_KQUORUM, 0)
    u.sq(VBE_KQUORUM + 8, 0)
    u.call('boot_quorum_check')
    check('no staged quorum change -> none latched',
          u.lb(u.data_addr['kquorum_present']) == 0)
    staged = qch_env(qch_payload(7, (2, 0x3F, 0x04), (3, 0x3F, 0x0C)), [1, 3, 4])
    st_addr = u.place(staged)
    u.sq(VBE_KQUORUM, st_addr)
    u.sq(VBE_KQUORUM + 8, len(staged))
    u.call('boot_quorum_check')
    check('staged quorum change accepted through the call site',
          u.lb(u.data_addr['kquorum_present']) == 1 and
          u.lw(u.data_addr['kquorum_rc']) == 0 and
          u.call('gate_quorum_active_min', 7) == 3 and
          u.call('gate_quorum_active_required', 7) == 0x0C,
          'rc=%d' % u.lw(u.data_addr['kquorum_rc']))

    # 9. RTC/now binding (gate_time_set / gate_time_now): envelope validity
    # windows are judged against a REAL, floor-clamped, forward-ratcheting
    # verifier clock - including on hash-cache hits.
    FLOOR = 1767225600                       # 2026-01-01 UTC (GATE_TIME_FLOOR)
    ENVR_ERR_WINDOW = 14
    check('verifier clock defaults to the build floor',
          u.call('gate_time_now') == FLOOR)
    u.call('gate_time_set', 5)               # dead-CMOS / rolled-back sample
    check('dead-RTC sample clamps to the floor (never the past)',
          u.call('gate_time_now') == FLOOR)
    NOW = 1781136000                         # 2026-06-11 UTC
    u.call('gate_time_set', NOW)
    check('RTC sample binds the verifier clock', u.call('gate_time_now') == NOW)
    u.call('gate_time_set', NOW - 86400)
    check('clock never moves backward within a boot (ratchet)',
          u.call('gate_time_now') == NOW)

    # upd_kw (update class) is untouched by the section-8 class-5/7 ratchets.
    exp_kw = dict(upd_kw); exp_kw.update(not_after=1000000000)
    rc = admit(we.build_envelope(payload=b'expired update', **exp_kw),
               ART_UPDATE)
    check('expired envelope rejected against the live clock (WINDOW)',
          rc == ENVR_ERR_WINDOW, 'rc=%d' % rc)
    fut_kw = dict(upd_kw); fut_kw.update(not_before=NOW + 86400)
    rc = admit(we.build_envelope(payload=b'postdated update', **fut_kw),
               ART_UPDATE)
    check('not-yet-valid envelope rejected (WINDOW)',
          rc == ENVR_ERR_WINDOW, 'rc=%d' % rc)
    win_kw = dict(upd_kw); win_kw.update(not_before=NOW - 100,
                                         not_after=NOW + 100)
    win_env = we.build_envelope(payload=b'windowed update', **win_kw)
    rc = admit(win_env, ART_UPDATE)
    check('tight window spanning now admitted', rc == 0, 'rc=%d' % rc)
    u.call('gate_time_set', NOW + 200)       # the window expires mid-boot
    rc = admit(win_env, ART_UPDATE)
    check('cached (already-verified) artifact still expires against the '
          'live clock', rc == ENVR_ERR_WINDOW, 'rc=%d' % rc)

    # 10. Persistent anti-rollback floors (floor_store.ghl): the gate's
    # required version/counter/epoch come from the floor table, ratchet
    # forward on every ACCEPTED envelope's signed monotonic fields, and
    # round-trip through the persisted sector record (host ATA stubs leave
    # floor_buf intact, so persist->load exercises the real encode/decode/
    # checksum path).
    ENVR_ERR_EPOCH, ENVR_ERR_DOWNGRADE, ENVR_ERR_REPLAY = 15, 16, 17
    rc = u.call('floor_store_load')         # kmain K5 order: load before admits
    check('first boot: readable media, no record yet (blank)',
          rc == 2, 'rc=%d' % rc)
    check('floors default to the build-time constant (1)',
          u.call('floor_required_version', ART_UPDATE) == 1 and
          u.call('floor_required_counter', ART_UPDATE) == 1 and
          u.call('floor_required_epoch', ART_UPDATE) == 1)
    check('out-of-range class answers an impossible floor (fail closed)',
          u.call('floor_required_version', 0) == 0xFFFFFFFF and
          u.call('floor_required_epoch', 10) == 0xFFFFFFFF)
    v3_kw = dict(upd_kw); v3_kw.update(version=3, rollback=2, epoch=2)
    rc = admit(we.build_envelope(payload=b'update v3', **v3_kw), ART_UPDATE)
    check('newer (v3/c2/e2) update admitted', rc == 0, 'rc=%d' % rc)
    check('accepted envelope ratchets the class floors',
          u.call('floor_required_version', ART_UPDATE) == 3 and
          u.call('floor_required_counter', ART_UPDATE) == 2 and
          u.call('floor_required_epoch', ART_UPDATE) == 2)
    check('floors are per-class (app class unaffected)',
          u.call('floor_required_version', ART_APP) == 1)
    old_kw = dict(v3_kw); old_kw.update(version=2)
    rc = admit(we.build_envelope(payload=b'superseded v2', **old_kw),
               ART_UPDATE)
    check('superseded version rejected (DOWNGRADE)',
          rc == ENVR_ERR_DOWNGRADE, 'rc=%d' % rc)
    old_kw = dict(v3_kw); old_kw.update(rollback=1)
    rc = admit(we.build_envelope(payload=b'replayed counter', **old_kw),
               ART_UPDATE)
    check('superseded rollback counter rejected (REPLAY)',
          rc == ENVR_ERR_REPLAY, 'rc=%d' % rc)
    old_kw = dict(v3_kw); old_kw.update(epoch=1)
    rc = admit(we.build_envelope(payload=b'stale epoch', **old_kw),
               ART_UPDATE)
    check('stale revocation epoch rejected (EPOCH)',
          rc == ENVR_ERR_EPOCH, 'rc=%d' % rc)
    rc = u.call('floor_persist', NOW + 200)
    check('raised floors persist to the floor sector', rc == 0, 'rc=%d' % rc)
    check('persist advances the clock high-water',
          u.call('floor_time_high') == NOW + 200)
    rc = u.call('floor_persist', NOW + 200)
    check('clean floors skip the sector rewrite', rc == 1, 'rc=%d' % rc)
    rc = u.call('floor_store_load')
    check('persisted record loads back (magic/fmt/checksum ok)',
          rc == 0, 'rc=%d' % rc)
    check('reload keeps the ratcheted floors (max-merge)',
          u.call('floor_required_version', ART_UPDATE) == 3)
    fb = u.data_addr['floor_buf']
    u.mem[fb + 30] ^= 0xFF                  # corrupt a class field on "disk"
    rc = u.call('floor_store_load')
    check('corrupt record detected by checksum -> treated as blank',
          rc == 2, 'rc=%d' % rc)
    check('corrupt record is never trusted (floors unchanged)',
          u.call('floor_required_version', ART_UPDATE) == 3)

    # 11. Cross-device replay (Track 2 sec->10: device_id fully unpinned).
    # The gate derives a REAL per-machine id from CPUID (gate_device_id_init);
    # there is no `=1` fallback in the verifier any more - gate_device_id()
    # answers the build-time WILDCARD (1) ONLY until init runs, and an
    # envelope that names a CONCRETE target device must EXACT-match this
    # machine's derived id (gate_device_for_target). We simulate two distinct
    # machines by writing the CPUID-derived state (gate_dev_id/gate_dev_init)
    # the kernel's gate_device_id_init would have produced, then prove an
    # envelope signed FOR device A is REJECTED on device B (ENVR_ERR_DEVICE),
    # accepted on device A, and that the device-agnostic (wildcard-target)
    # build artifacts still admit on any machine.
    ENVR_ERR_DEVICE = 12   # ENVR_ERR_TARGET_DEVICE (envelope_reader.ghl)
    DEV_A, DEV_B = 0xA1B2C3D4, 0x5E6F7081

    def set_machine(dev_id):
        # Stand in for gate_device_id_init's CPUID derivation: pin the derived
        # id + mark init done so gate_device_id() returns the REAL machine id
        # (no wildcard fallback) for the rest of this admission.
        u.sw(u.data_addr['gate_dev_id'], dev_id)
        u.sb(u.data_addr['gate_dev_init'], 1)

    # Envelope cryptographically bound to device A (TARGET_DEVICE EXACT == A).
    devA_kw = dict(gkw)
    devA_kw.update(min_cosigners=3, sig_count=3, device_id=DEV_A)
    devA_env = we.build_envelope(payload=b'artifact for machine A', **devA_kw)

    set_machine(DEV_A)
    rc = admit(devA_env, ART_APP)
    check('device-A-targeted envelope admitted on machine A', rc == 0,
          'rc=%d' % rc)

    set_machine(DEV_B)
    rc = admit(devA_env, ART_APP)
    check('cross-device replay: device-A envelope REJECTED on machine B '
          '(ENVR_ERR_DEVICE)', rc == ENVR_ERR_DEVICE, 'rc=%d' % rc)

    # A device-B-targeted envelope is the mirror image: rejected on A.
    devB_kw = dict(devA_kw); devB_kw.update(device_id=DEV_B)
    devB_env = we.build_envelope(payload=b'artifact for machine B', **devB_kw)
    set_machine(DEV_A)
    rc = admit(devB_env, ART_APP)
    check('cross-device replay: device-B envelope REJECTED on machine A '
          '(ENVR_ERR_DEVICE)', rc == ENVR_ERR_DEVICE, 'rc=%d' % rc)
    set_machine(DEV_B)
    rc = admit(devB_env, ART_APP)
    check('device-B-targeted envelope admitted on machine B', rc == 0,
          'rc=%d' % rc)

    # Device-agnostic build artifacts (wildcard target) admit on any machine -
    # the gate maps a wildcard-target envelope to the wildcard, never the
    # derived id, so build outputs stay portable.
    agnostic = we.build_envelope(payload=b'portable build artifact', **dict(
        gkw, min_cosigners=3, sig_count=3))   # gkw device_id=1 == WILDCARD
    for m in (DEV_A, DEV_B):
        set_machine(m)
        rc = admit(agnostic, ART_APP)
        check('device-agnostic (wildcard) artifact admits on machine '
              '0x%08X' % m, rc == 0, 'rc=%d' % rc)

    # Restore the host default (uninit -> wildcard) for any later use.
    u.sb(u.data_addr['gate_dev_init'], 0)

    # 12. Driver/Config/Policy artifact classes have LIVE, tested call sites
    # (Track 2 sec->10: every declared class is wired through the gate). The
    # call site (boot_artifact_class_check) latches a per-class verdict; absent
    # files latch "none", a validly signed class artifact latches accepted, and
    # a wrong-class artifact is refused (CALLER_TYPE) - so a declared class can
    # never be a silent no-op, and a mis-targeted artifact can never slip in.
    u.sb(u.data_addr['gate_dev_init'], 0)
    VBE_DRV, VBE_CFG, VBE_POL = 0x90D0, 0x90E0, 0x90F0
    ART_DRIVER, ART_CONFIG = 4, 7

    # Absent files -> all three latch "none" (present=0, rc=0).
    for off in (VBE_DRV, VBE_CFG, VBE_POL):
        u.sq(off, 0)
        u.sq(off + 8, 0)
    u.call('boot_artifact_class_check')
    check('absent driver/config/policy artifacts latch none',
          u.lb(u.data_addr['kdriver_present']) == 0 and
          u.lb(u.data_addr['kconfig_present']) == 0 and
          u.lb(u.data_addr['kpolicy_present']) == 0)

    # Build one validly signed artifact per class. The quorum policy (min 2,
    # POLICY-bit required, threshold mask 0x04) is the same per-class floor the
    # APP gkw envelopes satisfy; only the SIGNER_ROLE field (envelope field 6,
    # ROLE_DRIVER=3 / ROLE_POLICY=5 per signed_artifact_check.ghl) changes per
    # class. Auto-sign (sign_roles=None) builds a quorum from required_mask.
    def class_env(kind, domain, signer_role, mincos=None, reqmask=None):
        ckw = dict(gkw)
        ckw.update(kind=kind, domain=domain, role=signer_role, device_id=1)
        if mincos is not None:
            ckw.update(min_cosigners=mincos, sig_count=mincos)
        if reqmask is not None:
            ckw.update(required_mask=reqmask)
        return we.build_envelope(payload=b'class artifact %d' % kind, **ckw)

    drv_env = class_env(ART_DRIVER, 4, 3)   # signer ROLE_DRIVER
    # CONFIG (class 7) quorum was ratcheted to min 3 / required 0x0C by the
    # section-8 boot_quorum_check staged change; declare+sign at the active rule.
    cfg_env = class_env(ART_CONFIG, 7, 5, mincos=3, reqmask=0x0C)
    pol_env = class_env(ART_POLICY, 6, 5)   # signer ROLE_POLICY
    for off, env in ((VBE_DRV, drv_env), (VBE_CFG, cfg_env), (VBE_POL, pol_env)):
        a = u.place(env)
        u.sq(off, a)
        u.sq(off + 8, len(env))
    u.call('boot_artifact_class_check')
    check('signed driver artifact accepted through its call site',
          u.lb(u.data_addr['kdriver_present']) == 1 and
          u.lw(u.data_addr['kdriver_rc']) == 0,
          'rc=%d' % u.lw(u.data_addr['kdriver_rc']))
    check('signed config artifact accepted through its call site',
          u.lb(u.data_addr['kconfig_present']) == 1 and
          u.lw(u.data_addr['kconfig_rc']) == 0,
          'rc=%d' % u.lw(u.data_addr['kconfig_rc']))
    check('signed policy artifact accepted through its call site',
          u.lb(u.data_addr['kpolicy_present']) == 1 and
          u.lw(u.data_addr['kpolicy_rc']) == 0,
          'rc=%d' % u.lw(u.data_addr['kpolicy_rc']))

    # A validly-signed APP envelope staged in the DRIVER slot must be refused
    # (CALLER_TYPE): the class is bound at the call site, not just structurally.
    app_in_drv = we.build_envelope(payload=b'app masquerading as driver',
                                   **dict(gkw, min_cosigners=3, sig_count=3))
    a = u.place(app_in_drv)
    u.sq(VBE_DRV, a)
    u.sq(VBE_DRV + 8, len(app_in_drv))
    u.sq(VBE_CFG, 0); u.sq(VBE_CFG + 8, 0)
    u.sq(VBE_POL, 0); u.sq(VBE_POL + 8, 0)
    u.call('boot_artifact_class_check')
    check('wrong-class (app-in-driver-slot) artifact refused at the call site '
          '(CALLER_TYPE)', u.lw(u.data_addr['kdriver_rc']) == 23,
          'rc=%d' % u.lw(u.data_addr['kdriver_rc']))

    if FAILURES:
        sys.stderr.write('[ed25519] FAIL - %d problem(s):\n' % len(FAILURES))
        for f in FAILURES:
            sys.stderr.write('  - %s\n' % f)
        return 1
    print('[ed25519] real GHL Ed25519 verifier: RFC 8032 vectors + threshold '
          'envelope signatures all enforced')
    return 0


if __name__ == '__main__':
    sys.exit(main())
