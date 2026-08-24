package models

import "time"

type ReadingProgress struct {
    ID              string    `gorm:"primaryKey;type:varchar(36)" json:"id"`
    UserID          string    `gorm:"index;type:varchar(36);not null" json:"user_id"`
    BookID          string    `gorm:"index;type:varchar(64);not null" json:"book_id"`
    Title           string    `gorm:"type:varchar(255)" json:"title"`             // 👈 书名
    FilePath        string    `gorm:"type:varchar(512)" json:"file_path"`         // 👈 NAS 远端路径
    Progress        float64   `gorm:"type:real;not null;default:0" json:"progress"`
    Locator         string    `gorm:"type:text;not null" json:"locator"`
    DeviceID        string    `gorm:"type:varchar(64)" json:"device_id"`
    DeviceName      string    `gorm:"type:varchar(100)" json:"device_name"`
    ClientUpdatedAt int64     `gorm:"not null" json:"client_updated_at"`
    UpdatedAt       time.Time `json:"updated_at"`
}