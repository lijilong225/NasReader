package config

import (
	"log"
	"os"
	"path/filepath"

	"github.com/glebarez/sqlite" // 纯 Go 实现的 SQLite 驱动，无 CGO 依赖
	"gorm.io/gorm"
	"gorm.io/gorm/logger"

	"reader-sync/models"
)

var DB *gorm.DB

// InitDB 初始化 SQLite 数据库连接并自动迁移数据表
func InitDB() {
	dbDir := "data"
	dbFile := filepath.Join(dbDir, "reader.db")

	// 1. 确保数据持久化目录存在
	if err := os.MkdirAll(dbDir, 0755); err != nil {
		log.Fatalf("创建数据库目录失败: %v", err)
	}

	// 2. 连接 SQLite 数据库 (启用 _pragma 优化并发读取性能)
	var err error
	DB, err = gorm.Open(sqlite.Open(dbFile+"?_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)"), &gorm.Config{
		Logger: logger.Default.LogMode(logger.Info),
	})
	if err != nil {
		log.Fatalf("连接 SQLite 数据库失败: %v", err)
	}

	// 3. 自动迁移数据表结构
	err = DB.AutoMigrate(
		&models.User{},
		&models.ReadingProgress{},
	)
	if err != nil {
		log.Fatalf("数据库表自动迁移失败: %v", err)
	}

	log.Printf("SQLite 数据库初始化成功 (存储路径: %s)", dbFile)
}