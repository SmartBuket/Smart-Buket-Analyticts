FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

COPY libs/sb_common /app/libs/sb_common
COPY services/reco-api /app/services/reco-api

WORKDIR /app/services/reco-api

RUN python -m pip install --no-cache-dir --upgrade pip \
    && python -m pip install --no-cache-dir -r requirements.txt

EXPOSE 8080

# Cloud Run provides $PORT; default to 8080 for local runs.
CMD ["sh", "-c", "python -m uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8080}"]
