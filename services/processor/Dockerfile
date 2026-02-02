FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

COPY libs/sb_common /app/libs/sb_common
COPY services/processor /app/services/processor

WORKDIR /app/services/processor

RUN python -m pip install --no-cache-dir --upgrade pip \
    && python -m pip install --no-cache-dir -r requirements.txt

EXPOSE 8080

# Cloud Run services must listen on $PORT. We run the worker loop in a background thread
# and expose a tiny HTTP health endpoint.
CMD ["sh", "-c", "python -m app.cloudrun --port ${PORT:-8080}"]
