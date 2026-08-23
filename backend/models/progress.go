package models

import "time"

type ReadingProgress struct {
	ID              string    `gorm:"primaryKey;type:varchar(36)" json:"id"`
	UserID          string    `gorm:"index;type:varchar(36);not null" json:"user_id"`
	BookID          string    `gorm:"index;type:varchar(64);not null" json:"book_id"`
	Progress        float64   `gorm:"type:real;not null;default:0" json:"progress"` // 0.0 ~ 1.0
	Locator         string    `gorm:"type:text;not null" json:"locator"`             // JSON 字符串 (CFI / Char Offset)
	DeviceID        string    `gorm:"type:varchar(64)" json:"device_id"`
	DeviceName      string    `gorm:"type:varchar(100)" json:"device_name"`
	ClientUpdatedAt int64     `gorm:"not null" json:"client_updated_at"` // 客户端时间戳(毫秒)，用于防冲突
	UpdatedAt       time.Time `json:"updated_at"`
}