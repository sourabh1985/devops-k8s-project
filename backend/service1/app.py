from flask import Flask
app = Flask(__name__)

@app.route('/api')
def home():
    return {"message": "API working now."}  # small change

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)