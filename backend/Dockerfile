FROM golang:1.22-alpine AS builder

WORKDIR /app
RUN apk add --no-cache gcc musl-dev

COPY . .
# 自动拉取与整理所有依赖
RUN go mod tidy
RUN CGO_ENABLED=1 GOOS=linux go build -ldflags="-w -s" -o reader-server .

FROM alpine:latest
WORKDIR /app
RUN apk --no-cache add ca-certificates tzdata
COPY --from=builder /app/reader-server .

EXPOSE 8080
CMD ["./reader-server"]