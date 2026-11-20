import http.server, socketserver, os, sys

os.chdir(r"D:\work_machine\godot-orbit-dash\build")

class H(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()
    def log_message(self, *a):
        pass

socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", 8124), H) as httpd:
    print("serving on http://127.0.0.1:8124/", flush=True)
    httpd.serve_forever()
