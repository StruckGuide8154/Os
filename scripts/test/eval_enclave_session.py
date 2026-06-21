#!/usr/bin/env python3
# Track-10 enclave session-channel evaluation: executes the REAL gateware MODEL
# source (src/enclave/enclave_session.ghl) through the production GHL compiler's
# own lexer/parser/transpiler - the same Unit used by eval_ed25519.py /
# eval_enclave.py, so the logic under test is exactly what the .ghl declares.
#
# This is the CI stand-in for the FPGA wire protocol (docs/track10-...-todo.md
# "P0 - Authenticated session channel"): the host driver + board agree on a
# session key, mutually attest, and exchange AEAD frames, all without real
# hardware. The crypto primitives are models (enc_s_dh / enc_s_sign / enc_s_kdf)
# swapped for constant-time X25519/Ed25519/AEAD cores in silicon; what is tested
# here is the PROTOCOL: handshake ordering, mutual proof, channel + boot
# binding, and per-frame replay/reorder/inject rejection.
#
# The harness plays BOTH the honest host (driving its half through the module's
# OWN exposed primitives, so host<->board agreement is real interop, not a
# Python re-implementation) AND a USB-MITM (spoofed board, spoofed host, altered
# handshake fields, replayed/reordered/injected frames, cross-boot replay).
#
# Suite mirrors the track doc "P2 - Validation / USB-MITM tests":
#   1. honest mutual handshake -> both sides reach the SAME session key.
#   2. board proves identity (host rejects a wrong-key board).
#   3. host proves identity (board rejects a wrong-key host at finish).
#   4. a MITM that alters any handshake field breaks the transcript -> reject.
#   5. cross-boot replay of a handshake is refused (boot binding).
#   6. AEAD frames: in-order authentic frames open; replay, reorder, and
#      injected/tampered frames are all rejected and never advance state.
#   7. a captured session is inert on a later boot (different K_s).

import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
sys.path.insert(0, os.path.dirname(__file__))
from eval_ed25519 import Unit  # noqa: E402  reuse the production transpiler

MODULE = os.path.join(ROOT, 'src', 'enclave', 'enclave_session.ghl')

# Status codes (kept in lockstep with enclave_session.ghl; the const-drift guard
# below asserts these against the compiled module so they can't rot).
SS_OK, SS_BAD_PEER, SS_NO_SESS, SS_BAD_TAG, SS_BAD_SEQ, SS_STALE = 0, 1, 2, 3, 4, 5

M64 = 0xFFFFFFFFFFFFFFFF
FAILURES = []


def check(label, ok, detail=''):
    print('[encsess] %-54s [%s]%s' % (label, 'ok' if ok else 'FAIL',
                                      (' ' + detail if detail and not ok else '')))
    if not ok:
        FAILURES.append(label + (': ' + detail if detail else ''))


class Host:
    """The honest host driver, driving its half of the handshake through the
    board module's OWN exposed primitives, so any agreement we assert is real
    host<->board interop (not a separate Python crypto)."""

    def __init__(self, u, priv, seed):
        self.u = u
        self.priv = priv
        self.seed = seed
        G = u.consts['ENC_S_G']
        self.pub = u.call('enc_s_dh', priv, G) & M64

    def handshake(self, board_boot, expect_boot=None):
        """Run begin/finish against the board; return (rc_begin, rc_finish)."""
        u = self.u
        if expect_boot is None:
            expect_boot = board_boot
        rc_b = u.call('enclave_session_begin', self.pub, self.seed,
                      board_boot, expect_boot)
        if rc_b != SS_OK:
            return rc_b, None
        board_pub = u.call('enclave_session_board_pub') & M64
        board_attest = u.call('enclave_session_board_attest') & M64
        # Host verifies the BOARD (board half of mutual attestation).
        tr = u.call('enclave_session_transcript', self.pub, board_pub,
                    board_boot) & M64
        expect_board_sig = u.call('enc_s_sign', u.consts['ENC_S_BOARD_ID'],
                                  tr) & M64
        self.board_ok = (board_attest == expect_board_sig)
        self.tr = tr
        self.board_pub = board_pub
        # Host proves ITSELF (host half).
        host_attest = u.call('enc_s_sign', u.consts['ENC_S_HOST_ID'], tr)
        rc_f = u.call('enclave_session_finish', host_attest)
        return rc_b, rc_f

    def session_key(self):
        """What the host independently derives K_s to be."""
        u = self.u
        shared = u.call('enc_s_dh', self.priv, self.board_pub) & M64
        return u.call('enc_s_kdf', u.consts['ENC_S_DOM_KDF'],
                      shared ^ self.tr, self._boot) & M64

    def aead_tag(self, seq, ct, key):
        u = self.u
        return u.call('enc_s_kdf', u.consts['ENC_S_DOM_AEAD'],
                      (key ^ seq) & M64, ct) & M64


def main():
    u = Unit([MODULE])
    print('[encsess] transpiled %d fns, %d data symbols, %d consts '
          '(production gritc frontend)' % (len(u.fns), len(u.data), len(u.consts)))

    # 0. const-drift guard: the status codes this harness asserts against MUST
    #    equal the compiled module's, so the test can never silently diverge.
    cd = u.consts
    check('status constants match the module', all([
        cd['SS_OK'] == SS_OK, cd['SS_BAD_PEER'] == SS_BAD_PEER,
        cd['SS_NO_SESS'] == SS_NO_SESS, cd['SS_BAD_TAG'] == SS_BAD_TAG,
        cd['SS_BAD_SEQ'] == SS_BAD_SEQ, cd['SS_STALE'] == SS_STALE,
    ]))

    # frame before any session: nothing decodes.
    u.call('enclave_session_reset')
    check('frame_open before a session -> SS_NO_SESS',
          u.call('enclave_frame_open', 1, 0xAA, 0) == SS_NO_SESS)
    check('frame_seal before a session -> SS_NO_SESS',
          u.call('enclave_frame_seal', 0xAA) == SS_NO_SESS)

    BOOT = 7

    # 1. honest mutual handshake -> the SAME session key on both sides.
    host = Host(u, priv=0x1111222233334444, seed=0xCAFEF00D)
    host._boot = BOOT
    rc_b, rc_f = host.handshake(BOOT)
    check('begin accepted', rc_b == SS_OK, 'rc=%s' % rc_b)
    check('host verifies the board identity (board half)', host.board_ok)
    check('finish accepted -> mutual handshake complete', rc_f == SS_OK,
          'rc=%s' % rc_f)
    check('session established', u.call('enclave_session_established') == 1)
    ks_board = u.call('enclave_session_key') & M64
    ks_host = host.session_key()
    check('host and board derive the SAME session key (interop)',
          ks_board == ks_host, 'board=%#x host=%#x' % (ks_board, ks_host))
    check('session key is non-trivial', ks_board not in (0, M64))

    # 2. board proves identity: a wrong-key board fails the host's check.
    forged_board_sig = u.call('enc_s_sign', 0xDEADDEADDEADDEAD, host.tr) & M64
    real_board_sig = u.call('enclave_session_board_attest') & M64
    check('a wrong-key (spoofed) board would fail the host check',
          forged_board_sig != real_board_sig)

    # 3. host proves identity: board rejects a wrong-key host at finish.
    host.handshake(BOOT)  # re-begin (sets pending)
    u.call('enclave_session_reset')
    rc_b = u.call('enclave_session_begin', host.pub, host.seed, BOOT, BOOT)
    tr = u.call('enclave_session_transcript', host.pub,
                u.call('enclave_session_board_pub') & M64, BOOT) & M64
    forged_host_attest = u.call('enc_s_sign', 0x0BADC0DE0BADC0DE, tr)
    rc_f = u.call('enclave_session_finish', forged_host_attest)
    check('board rejects a spoofed host at finish (SS_BAD_PEER)',
          rc_f == SS_BAD_PEER, 'rc=%s' % rc_f)
    check('failed handshake leaves no half-open session (fail-closed)',
          u.call('enclave_session_established') == 0)

    # 4. MITM alters a handshake field: the transcript diverges -> reject.
    #    Attacker flips host_pub on the wire; the board's transcript no longer
    #    matches the one the honest host signed.
    u.call('enclave_session_reset')
    u.call('enclave_session_begin', host.pub ^ 0xFF, host.seed, BOOT, BOOT)
    # honest host signed over the ORIGINAL transcript (its real pub)
    tr_honest = u.call('enclave_session_transcript', host.pub,
                       u.call('enclave_session_board_pub') & M64, BOOT) & M64
    host_attest = u.call('enc_s_sign', cd['ENC_S_HOST_ID'], tr_honest)
    rc_f = u.call('enclave_session_finish', host_attest)
    check('MITM-altered handshake field breaks binding (SS_BAD_PEER)',
          rc_f == SS_BAD_PEER, 'rc=%s' % rc_f)

    # 5. cross-boot replay: a handshake whose expected boot != live boot refused.
    u.call('enclave_session_reset')
    rc = u.call('enclave_session_begin', host.pub, host.seed, BOOT, BOOT - 1)
    check('cross-boot handshake replay refused (SS_STALE)', rc == SS_STALE,
          'rc=%s' % rc)
    check('SS_STALE leaves no session', u.call('enclave_session_established') == 0)

    # 6. AEAD frames: relay/replay/reorder/inject all rejected.
    u.call('enclave_session_reset')
    host.handshake(BOOT)
    key = u.call('enclave_session_key') & M64
    check('rx/tx sequences armed at 1',
          u.call('enclave_session_rx_seq') == 1 and
          u.call('enclave_session_tx_seq') == 1)

    # honest in-order frame opens and exposes its plaintext.
    ct1 = 0x1234567890ABCDEF
    tag1 = host.aead_tag(1, ct1, key)
    rc = u.call('enclave_frame_open', 1, ct1, tag1)
    check('in-order authentic frame opens (SS_OK)', rc == SS_OK, 'rc=%s' % rc)
    check('opened frame exposes its plaintext',
          (u.call('enclave_frame_plain') & M64) == ct1)
    check('rx advanced to 2', u.call('enclave_session_rx_seq') == 2)

    # replay the old frame -> rejected (seq already consumed).
    rc = u.call('enclave_frame_open', 1, ct1, tag1)
    check('replayed frame rejected (SS_BAD_SEQ)', rc == SS_BAD_SEQ, 'rc=%s' % rc)

    # injected/tampered frame at the right seq but wrong tag -> rejected.
    rc = u.call('enclave_frame_open', 2, 0xBADBADBAD, 0xDEAD)
    check('injected/tampered frame rejected (SS_BAD_TAG)', rc == SS_BAD_TAG,
          'rc=%s' % rc)
    check('a rejected frame does not advance rx',
          u.call('enclave_session_rx_seq') == 2)

    # reorder: a future seq before the expected one -> rejected.
    ct3 = 0xAAAABBBBCCCCDDDD
    tag3 = host.aead_tag(3, ct3, key)
    rc = u.call('enclave_frame_open', 3, ct3, tag3)
    check('reordered (gapped) frame rejected (SS_BAD_SEQ)', rc == SS_BAD_SEQ,
          'rc=%s' % rc)

    # the correct next in-order frame still opens.
    ct2 = 0x0F0F0F0F0F0F0F0F
    tag2 = host.aead_tag(2, ct2, key)
    rc = u.call('enclave_frame_open', 2, ct2, tag2)
    check('correct next in-order frame opens after the rejects', rc == SS_OK,
          'rc=%s' % rc)
    check('rx advanced to 3', u.call('enclave_session_rx_seq') == 3)

    # board-emitted (sealed) frame: tag is what the host expects, tx advances.
    tx_before = u.call('enclave_session_tx_seq')
    seal_tag = u.call('enclave_frame_seal', ct1) & M64
    check('board seal stamps the expected tag (host can open it)',
          seal_tag == host.aead_tag(tx_before, ct1, key))
    check('tx advanced after seal',
          u.call('enclave_session_tx_seq') == tx_before + 1)

    # 7. a captured session is inert on a later boot: different K_s.
    u.call('enclave_session_reset')
    host.handshake(BOOT)
    ks_b7 = u.call('enclave_session_key') & M64
    u.call('enclave_session_reset')
    host._boot = BOOT + 1
    host.handshake(BOOT + 1)
    ks_b8 = u.call('enclave_session_key') & M64
    check('same handshake on a later boot yields a different key '
          '(no cross-boot session replay)', ks_b7 != ks_b8,
          'b7=%#x b8=%#x' % (ks_b7, ks_b8))

    if FAILURES:
        sys.stderr.write('[encsess] FAIL - %d problem(s):\n' % len(FAILURES))
        for f in FAILURES:
            sys.stderr.write('  - %s\n' % f)
        return 1
    print('[encsess] authenticated session channel: mutual attestation, '
          'channel+boot binding, and AEAD replay/reorder/inject rejection all '
          'enforced (Track 10 P0 model)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
