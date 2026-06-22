from flask import Flask, jsonify
import os
import socket

app = Flask(__name__)

SERVICE_NAME = "service3"
VERSION = os.environ.get("APP_VERSION", "v1")

@app.route('/api/service3')
def home():
    return jsonify({
        "service": SERVICE_NAME,
        "version": VERSION,
        "message": "Hello from Service 3 - Product Service",
        "host": socket.gethostname()
    })

@app.route('/health')
def health():
    return jsonify({"status": "healthy", "service": SERVICE_NAME})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5002)
