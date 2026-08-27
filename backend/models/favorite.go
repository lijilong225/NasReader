// models/favorite.go
package models

// Favorite 收藏夹条目，按 (user_id, book_id) 唯一。
// ClientUpdatedAt 为客户端毫秒时间戳，用于 LWW 合并；IsDeleted 为取消收藏的墓碑标记。
type Favorite struct {
	UserID          string `gorm:"primaryKey;type:varchar(64);not null" json:"user_id"`
	BookID          string `gorm:"primaryKey;type:varchar(128);not null" json:"book_id"`
	Title           string `gorm:"type:varchar(255)" json:"title"`
	FileName        string `gorm:"type:varchar(255)" json:"file_name"`
	RemotePath      string `gorm:"type:varchar(512)" json:"remote_path"`
	AddedAt         int64  `gorm:"not null;default:0" json:"added_at"`
	ClientUpdatedAt int64  `gorm:"not null;default:0" json:"updated_at"`
	IsDeleted       bool   `gorm:"not null;default:false" json:"is_deleted"`
}

type SyncFavoritesRequest struct {
	Favorites []Favorite `json:"favorites"`
}
