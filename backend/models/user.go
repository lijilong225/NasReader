package models

import "time"

type User struct {
	ID        string    `gorm:"primaryKey;type:varchar(36)" json:"id"`
	Username  string    `gorm:"uniqueIndex;not null;type:varchar(50)" json:"username"`
	Password  string    `gorm:"not null" json:"-"` // 不返回前端
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}