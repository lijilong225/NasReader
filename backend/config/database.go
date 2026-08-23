package config

import (
	"log"
	"reader-sync/models"

	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

var DB *gorm.DB

func InitDB() {
	var err error
	// 启用 WAL 模式提高并发读写性能
	DB, err = gorm.Open(sqlite.Open("reader_sync.db?_journal_mode=WAL"), &gorm.Config{
		Logger: logger.Default.LogMode(logger.Info),
	})
	if err != nil {
		log.Fatalf("Failed to connect database: %v", err)
	}

	// 自动迁移表结构
	err = DB.AutoMigrate(
		&models.User{},
		&models.ReadingProgress{},
	)
	if err != nil {
		log.Fatalf("Database migration failed: %v", err)
	}
}