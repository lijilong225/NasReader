FROM golang:1.22-alpine AS builder

WORKDIR /app

# 先单独下载依赖，命中缓存层；go.sum 已入库，构建期不再 tidy，保证可复现
COPY go.mod go.sum ./
RUN go mod download

COPY . .

# 纯 Go 静态编译，跨平台秒编通过
RUN CGO_ENABLED=0 GOOS=linux go build -mod=readonly -ldflags="-w -s" -o reader-server .

FROM alpine:latest
WORKDIR /app

RUN apk --no-cache add ca-certificates tzdata
COPY --from=builder /app/reader-server .

EXPOSE 8080
CMD ["./reader-server"]