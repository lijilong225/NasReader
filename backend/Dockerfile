FROM golang:1.22-alpine AS builder

WORKDIR /app

# 安装 C 编译工具链支持 CGO SQLite
RUN apk add --no-cache gcc musl-dev

COPY go.mod go.sum* ./
RUN go mod download || true

COPY . .

# 开启 CGO 编译
RUN CGO_ENABLED=1 GOOS=linux go build -ldflags="-w -s" -o reader-server .

# 运行阶段
FROM alpine:latest
WORKDIR /app
RUN apk --no-cache add ca-certificates tzdata
COPY --from=builder /app/reader-server .

EXPOSE 8080
CMD ["./reader-server"]