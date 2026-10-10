FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN groupadd --system queue && useradd --system --gid queue --home-dir /app queue

WORKDIR /app
COPY --chown=queue:queue server.py /app/server.py

RUN mkdir /data && chown queue:queue /data

USER queue
EXPOSE 56789
VOLUME ["/data"]

HEALTHCHECK --interval=10s --timeout=3s --start-period=3s --retries=3 \
    CMD ["python", "-c", "import http.client; c=http.client.HTTPConnection('127.0.0.1',56789,timeout=2); c.request('GET','/health',headers={'Connection':'close'}); r=c.getresponse(); r.read(); status=r.status; c.close(); raise SystemExit(0 if status == 200 else 1)"]

ENTRYPOINT ["python", "/app/server.py"]