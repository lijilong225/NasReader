FROM golang:1.22-alpine AS builder

WORKDIR /app

# 复制所有源码
COPY . .

# 整理依赖
RUN go mod tidy

# 纯 Go 静态编译，跨平台秒编通过
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-w -s" -o reader-server .

FROM alpine:latest
WORKDIR /app

RUN apk --no-cache add ca-certificates tzdata
COPY --from=builder /app/reader-server .

EXPOSE 8080
CMD ["./reader-server"]