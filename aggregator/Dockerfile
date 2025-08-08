FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
ENV FLASK_APP=app.py
ENV AGG_API_TOKEN=changeme
EXPOSE 5000
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "app:app", "--workers", "2"]


# This Dockerfile sets up a Python environment for the IT Automated Health Check Tool.
# It installs the required dependencies, copies the application code, sets environment variables,
# exposes port 5000, and starts the application using Gunicorn with two worker processes.
# This Dockerfile is used to build a Docker image for the IT Automated Health Check Tool's aggregator service.
# It is designed to run a Flask application with Gunicorn, ensuring that the application is production-ready.
# It includes the necessary dependencies and configurations to run the application in a Docker container.
# The Dockerfile is part of the aggregator service for the IT Automated Health Check Tool.
# It is used to build a Docker image that can be deployed in a containerized environment.