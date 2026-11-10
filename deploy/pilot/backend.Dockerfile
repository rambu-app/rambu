FROM python:3.12-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UV_PROJECT_ENVIRONMENT=/opt/rambu-venv \
    PATH=/opt/rambu-venv/bin:$PATH

RUN useradd --create-home --uid 10001 rambu
COPY --from=ghcr.io/astral-sh/uv:0.8.22 /uv /uvx /bin/

WORKDIR /app/backend
COPY backend/pyproject.toml backend/uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project

COPY backend/rambu_api ./rambu_api
RUN uv sync --frozen --no-dev \
    && mkdir -p /app/backend/data \
    && chown -R rambu:rambu /app/backend/data

USER rambu
EXPOSE 8000

CMD ["uvicorn", "rambu_api.app:app", "--host", "0.0.0.0", "--port", "8000"]
