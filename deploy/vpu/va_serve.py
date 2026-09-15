#!/usr/bin/env python3
"""Serve the VA-API browser test page from inside the guest -- with THREADS.

B21-browser lost three Epiphany runs to `python3 -m http.server`: it is single-threaded, so the
keep-alive connection a pkill'ed WebKit/Firefox leaves behind blocks every later request, and the
next browser stalls right after qtdemux with no decoder element autoplugged and nothing on the
phone. This is the same server with a ThreadingTCPServer underneath and keep-alive left to die on
its own thread. Copy it into the guest (guest.sh scp) and run it in the page directory:

    python3 va_serve.py 8080          # serves ./ (put 1080p.mp4 and index.html there)

The page it expects, so the browsers autoplay without a gesture:
    <video autoplay muted playsinline controls src="1080p.mp4"></video>
"""
import http.server
import socketserver
import sys


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    handler = http.server.SimpleHTTPRequestHandler
    with Server(("0.0.0.0", port), handler) as httpd:
        print(f"va_serve: threading http server on 0.0.0.0:{port}, serving {httpd.RequestHandlerClass.__name__}", flush=True)
        httpd.serve_forever()


if __name__ == "__main__":
    main()
