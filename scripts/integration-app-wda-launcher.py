#!/usr/bin/env python3

import http.server
import pathlib
import signal
import socket
import socketserver
import subprocess
import threading


PROJECT_ROOT = pathlib.Path(__file__).resolve().parent.parent
START_SCRIPT = PROJECT_ROOT / "Scripts" / "start-wda.sh"
LOG_PATH = pathlib.Path("/tmp/wda-from-integration-app.log")
process = None
lock = threading.Lock()
shutdown_event = threading.Event()


def launch_wda():
    global process
    with lock:
        if process is not None and process.poll() is None:
            return
        log = LOG_PATH.open("ab", buffering=0)
        process = subprocess.Popen(
            [str(START_SCRIPT)],
            cwd=PROJECT_ROOT,
            stdout=log,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/start":
            self.send_error(404)
            return
        threading.Thread(target=launch_wda, daemon=True).start()
        self.send_response(202)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"status":"starting"}\n')

    def log_message(self, message, *args):
        print(f"{self.client_address[0]} - {message % args}", flush=True)


class ThreadingIPv4Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    allow_reuse_address = True
    daemon_threads = True


class ThreadingIPv6Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    address_family = socket.AF_INET6
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    servers = [
        ThreadingIPv4Server(("0.0.0.0", 8200), Handler),
        ThreadingIPv6Server(("::", 8200), Handler),
    ]
    service_name = f"WDA Launcher on {socket.gethostname().split('.')[0]}"
    bonjour = subprocess.Popen(
        ["/usr/bin/dns-sd", "-R", service_name, "_wda-launcher._tcp", "local.", "8200"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.STDOUT,
    )

    def stop(*_args):
        shutdown_event.set()

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    try:
        for server in servers:
            threading.Thread(target=server.serve_forever, daemon=True).start()
        print(
            f"IntegrationApp WDA launcher '{service_name}' published via Bonjour on port 8200",
            flush=True,
        )
        shutdown_event.wait()
    finally:
        for server in servers:
            server.shutdown()
            server.server_close()
        bonjour.terminate()
        try:
            bonjour.wait(timeout=2)
        except subprocess.TimeoutExpired:
            bonjour.kill()
