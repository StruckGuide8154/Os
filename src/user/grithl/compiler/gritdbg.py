#!/usr/bin/env python3
# GritHL serial debugger.
# Connects to QEMU's TCP serial (127.0.0.1:5555 by default) and prints any
# `[ghll] ...` markers from running HL apps, plus kernel trace for context.
# Exits cleanly on Ctrl+C or after --deadline seconds of silence.

import socket, sys, time, argparse, re

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--host",default="127.0.0.1")
    ap.add_argument("--port",type=int,default=5555)
    ap.add_argument("--grep",default=r"\[ghll\]")
    ap.add_argument("--deadline",type=float,default=20.0,help="abort after N seconds of no bytes")
    ap.add_argument("--max-seconds",type=float,default=120.0)
    args=ap.parse_args()

    pat=re.compile(args.grep)
    s=socket.socket(); s.settimeout(3.0)
    s.connect((args.host,args.port))
    s.settimeout(1.0)
    buf=b""; last=time.time(); start=time.time()
    hits=0
    try:
        while True:
            if time.time()-start>args.max_seconds: break
            try:
                chunk=s.recv(4096)
            except socket.timeout:
                if time.time()-last>args.deadline: break
                continue
            if not chunk: break
            last=time.time()
            buf+=chunk
            while b"\n" in buf:
                line,buf=buf.split(b"\n",1)
                txt=line.decode("latin-1","replace").rstrip("\r")
                if pat.search(txt):
                    hits+=1
                    print(f"HIT {hits}: {txt}")
                else:
                    print(f"    {txt}")
    finally:
        s.close()
    print(f"[gritdbg] done, {hits} marker hit(s)")

if __name__=="__main__":
    main()
