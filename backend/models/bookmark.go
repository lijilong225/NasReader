// models/bookmark.go
package models

import "time"

type Bookmark struct {
	ID              string    `gorm:"primaryKey;type:varchar(128)" json:"id"`
	UserID          uint      `gorm:"index:idx_user_book;not null" json:"userId"` // 关联当前 JWT 用户
	BookID          string    `gorm:"index:idx_user_book;type:varchar(128);not null" json:"bookId"`
	Title           string    `gorm:"type:text;not null" json:"title"`
	Snippet         string    `gorm:"type:text" json:"snippet"`
	ProgressPercent float64   `gorm:"type:real;default:0.0" json:"progressPercent"`
	ByteOffset      *int64    `gorm:"type:bigint" json:"byteOffset"`
	CFI             *string   `gorm:"type:text" json:"cfi"`
	CreatedAt       time.Time `gorm:"type:datetime;not null" json:"createdAt"`
	UpdatedAt       time.Time `gorm:"type:datetime;not null" json:"updatedAt"`
	IsDeleted       bool      `gorm:"type:boolean;default:false" json:"isDeleted"`
}

type SyncBookmarkRequest struct {
	BookID    string     `json:"bookId" binding:"required"`
	Bookmarks []Bookmark `json:"bookmarks"`
}