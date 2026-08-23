这里为你整理了一份结构清晰、专业完整的 **`README.md`** 项目介绍文档，涵盖了架构设计、技术栈、核心功能以及前后端部署指南。

---

# NAS Reader - 私有云电子书阅读与同步系统

---

## 📖 项目简介

**NAS Reader** 是一套专为 NAS（网络附加存储）及私有服务器用户打造的电子书阅读解决方案。采用**前后端分离**架构，移动端使用 Flutter 开发，后端基于 Go (Gin) 驱动。

系统支持直接浏览 NAS 挂载目录，流式读取与缓存 **TXT** 和 **EPUB** 格式书籍，并具备多端阅读进度云端同步、暗黑模式切换、本地缓存管理及内置网络诊断日志等功能。

---

## ✨ 核心特性

* 📂 **NAS 目录云端直连**：递归浏览 NAS 目录结构，支持文件夹层级跳转与文件类型快速过滤。
* 📚 **多格式图书阅读**：
* **TXT**：分页流式加载，降低大文件内存占用。
* **EPUB**：原生排版解析，保留章节结构与插图。


* 🔄 **跨设备进度同步**：采用快速文件指纹（首尾哈希）识别同源书籍，自动同步多端阅读百分比与章节进度。
* 🔐 **轻量鉴权安全**：基于 JWT 的身份认证与鉴权，针对私有 NAS 环境设计，支持动态配置服务器地址。
* 🎨 **现代化 UI & 个性化设置**：
* 支持 Material 3 设计规范。
* 支持浅色模式 / 深色模式（Dark Mode）/ 跟随系统。
* 本地缓存管理，一键查看占用容量并支持缓存清理。


* 🛠 **内置网络日志诊断**：内置内存 HTTP 抓包浮窗，在真机无控制台连接环境下即可实时排查 API 404/500 异常。
* 🚀 **自动化 CI/CD**：集成 GitHub Actions，Git Tag 推送后自动注入版本号并构建分发 `NasReader-<Tag>.apk`。

---

## 🏗 技术架构与技术栈

### 技术选型

| 模块 | 技术栈 | 说明 |
| --- | --- | --- |
| **前端 (Android/iOS)** | Flutter 3.x / Dart | 跨平台移动端开发 |
| **网络请求** | Dio 5.x | 支持拦截器、Token 自动附加、Range 文件下载 |
| **本地持久化** | `shared_preferences` / `path_provider` | 配置项、Token 存储与本地书籍沙盒管理 |
| **后端 API** | Go 1.21+ / Gin | 高性能轻量 RESTful API 引擎 |
| **数据库** | SQLite / GORM | 存储用户数据与阅读进度（单文件零运维） |
| **持续集成** | GitHub Actions | 自动化 APK 构建、语义化版本注入与 Release 发布 |

### 核心 API 设计

```text
/api/v1
├── /auth
│   ├── POST /login         # 用户登录获取 JWT
│   └── POST /register      # 新用户注册 (可选)
├── /files
│   ├── GET  /browse        # 浏览 NAS 目录结构 (?path=/...)
│   └── GET  /download      # 支持 Range 断点续传的文件下载
└── /sync
    ├── GET  /progress      # 获取所有书籍阅读进度
    ├── GET  /progress/:id  # 获取单本书籍进度
    └── POST /progress      # 提交并更新最新阅读进度

```

---

## 📂 项目结构

```text
nas-reader/
├── .github/
│   └── workflows/
│       └── build-frontend-apk.yml   # 自动编译与 Release 打包流
├── backend/                         # Go 后端服务
│   ├── config/                      # 数据库与全局配置
│   ├── handlers/                    # 路由业务逻辑 (文件浏览/下载/同步)
│   ├── middleware/                  # JWT 鉴权与 CORS 中间件
│   ├── models/                      # 数据库实体定义
│   └── main.go                      # 后端入口
└── frontend/                        # Flutter 前端项目
    ├── lib/
    │   ├── pages/                   # 本地书架 / NAS 浏览器 / 设置 / 登录
    │   ├── readers/                 # TXT / EPUB 阅读器核心渲染组件
    │   ├── services/                # AuthService / AppLogger 网络与存储服务
    │   ├── main_navigation_container.dart # 底部主导航容器
    │   └── main.dart                # 应用入口与全局主题管理
    └── pubspec.yaml                 # 前端依赖配置

```

---

## 🚀 快速上手与部署

### 1. 后端部署 (Go)

#### 本地 / 物理机运行

```bash
cd backend

# 指定 NAS 书籍物理存储路径（默认 /nas/books）
export NAS_BOOKS_DIR="/your/nas/books/path"

# 下载依赖并运行
go mod tidy
go run main.go

```

#### Docker Compose 部署 (推荐)

```yaml
version: '3.8'

services:
  nas-reader-server:
    image: golang:1.21-alpine
    working_dir: /app
    volumes:
      - ./backend:/app
      - /volume1/books:/nas/books:ro  # 挂载 NAS 实际书籍目录
    environment:
      - NAS_BOOKS_DIR=/nas/books
      - GIN_MODE=release
    ports:
      - "6088:8080"
    command: go run main.go
    restart: unless-stopped

```

---

### 2. 前端开发与打包 (Flutter)

#### 运行与调试

```bash
cd frontend

# 安装依赖
flutter pub get

# 启动调试
flutter run

```

#### 本地手动构建 Release APK

```bash
flutter build apk --release --build-name=1.0.0 --build-number=1

```

#### 通过 GitHub Actions 自动化发布

只需要打上语义化版本 Tag 并推送到远程仓库：

```bash
git tag v1.0.0
git push origin v1.0.0

```

GitHub Actions 会自动编译生成名为 **`NasReader-v1.0.0.apk`** 的安装包，并发布至 GitHub Releases。

---

## 📝 开源协议

本项目基于 [MIT License](https://www.google.com/search?q=LICENSE) 协议开源。