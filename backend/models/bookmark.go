// models/bookmark.go
package models

type Bookmark struct {
	ID              string  `gorm:"primaryKey;type:varchar(128)" json:"id"`
	UserID          string  `gorm:"index:idx_user_book;type:varchar(64);not null" json:"userId"`
	BookID          string  `gorm:"index:idx_user_book;type:varchar(128);not null" json:"bookId"`
	Title           string  `gorm:"type:text;not null" json:"title"`
	Snippet         string  `gorm:"type:text" json:"snippet"`
	ProgressPercent float64 `gorm:"type:real;default:0.0" json:"progressPercent"`
	ByteOffset      *int64  `gorm:"type:bigint" json:"byteOffset"`
	CFI             *string `gorm:"type:text" json:"cfi"`
	CreatedAt       int64   `gorm:"type:bigint;not null" json:"createdAt"` // 毫秒时间戳
	UpdatedAt       int64   `gorm:"type:bigint;not null" json:"updatedAt"` // 毫秒时间戳
	IsDeleted       bool    `gorm:"type:boolean;default:false" json:"isDeleted"`
}

type SyncBookmarkRequest struct {
	BookID    string     `json:"bookId" binding:"required"`
	Bookmarks []Bookmark `json:"bookmarks"`
}