import os
from flask import Flask, jsonify
from aws_xray_sdk.core import xray_recorder
from aws_xray_sdk.ext.flask.middleware import XRayMiddleware

# Get environment variables
app_config = os.environ.get('MY_APP_CONFIG')
db_password = os.environ.get('MY_DB_PASSWORD')
service_name = os.environ.get('SERVICE_NAME')

# Initialize Flask app
app = Flask(__name__)

# Configure X-Ray
xray_recorder.configure(service=service_name or 'azni-flask-app')
XRayMiddleware(app, xray_recorder)

@app.route("/")
@xray_recorder.capture('index')
def index():
    # Create a subsegment for business logic
    subsegment = xray_recorder.begin_subsegment('prepare-response')
    try:
        response = {
            "message": "Hello from Azni!",
            "config": app_config,
            "db_credentials": {
                "password": "*****" if db_password else None
            }
        }
        # Add annotation to the subsegment
        xray_recorder.put_annotation('response_size', len(str(response)))
        return jsonify(response)
    finally:
        xray_recorder.end_subsegment()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)