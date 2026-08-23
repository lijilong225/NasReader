FROM golang:1.22-alpine AS builder

WORKDIR /app

# 使用 go.sum* 容错
COPY go.mod go.sum* ./
RUN go mod download || true

# 拷贝其余源码
COPY . .

# 静态编译二进制
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-w -s" -o reader-server .

# 生产运行镜像
FROM alpine:latest
WORKDIR /app

RUN apk --no-cache add ca-certificates tzdata
COPY --from=builder /app/reader-server .

EXPOSE 8080
CMD ["./reader-server"]