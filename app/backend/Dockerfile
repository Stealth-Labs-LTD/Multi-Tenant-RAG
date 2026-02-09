FROM node:20-alpine AS frontend-build
WORKDIR /frontend
COPY app/frontend/ .
ARG VITE_APP_ID
ENV VITE_APP_ID=${VITE_APP_ID}
RUN npm ci && npm run build

FROM python:3.12-slim
WORKDIR /app
COPY app/backend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app/backend/ .
COPY --from=frontend-build /frontend/dist ./static
EXPOSE 8080
CMD ["hypercorn", "app:app", "--bind", "0.0.0.0:8080"]
