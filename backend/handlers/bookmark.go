// handlers/bookmark.go
package handlers

import (
	"net/http"
	"reader-sync/config"
	"reader-sync/models"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

// SyncBookmarks 双向合并同步用户指定书籍的书签
func SyncBookmarks(c *gin.Context) {
	// 统一从上下文读取 string 类型的 user_id
	userID := c.GetString("user_id")
	if userID == "" {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "未获取到用户身份"})
		return
	}

	var req models.SyncBookmarkRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求参数无效: " + err.Error()})
		return
	}

	db := config.DB

	// 开启事务处理比对
	err := db.Transaction(func(tx *gorm.DB) error {
		var serverBookmarks []models.Bookmark
		if err := tx.Where("user_id = ? AND book_id = ?", userID, req.BookID).Find(&serverBookmarks).Error; err != nil {
			return err
		}

		serverMap := make(map[string]models.Bookmark, len(serverBookmarks))
		for _, b := range serverBookmarks {
			serverMap[b.ID] = b
		}

		for _, clientB := range req.Bookmarks {
			clientB.UserID = userID
			clientB.BookID = req.BookID

			serverB, exist := serverMap[clientB.ID]
			if !exist {
				// 服务端无记录：直接插入
				if err := tx.Create(&clientB).Error; err != nil {
					return err
				}
			} else {
				// 服务端存在：客户端较新时更新
				if clientB.UpdatedAt.After(serverB.UpdatedAt) {
					if err := tx.Model(&models.Bookmark{}).
						Where("id = ? AND user_id = ?", clientB.ID, userID).
						Updates(map[string]interface{}{
							"title":            clientB.Title,
							"snippet":          clientB.Snippet,
							"progress_percent": clientB.ProgressPercent,
							"byte_offset":      clientB.ByteOffset,
							"cfi":              clientB.CFI,
							"updated_at":       clientB.UpdatedAt,
							"is_deleted":       clientB.IsDeleted,
						}).Error; err != nil {
						return err
					}
				}
			}
		}
		return nil
	})

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "书签同步失败: " + err.Error()})
		return
	}

	// 返回该用户该书籍的所有最新书签
	var mergedList []models.Bookmark
	if err := db.Where("user_id = ? AND book_id = ?", userID, req.BookID).
		Order("created_at desc").
		Find(&mergedList).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取书签失败: " + err.Error()})
		return
	}

	c.JSON(http.StatusOK, mergedList)
}

// GetBookmarks 获取指定书籍的书签列表
func GetBookmarks(c *gin.Context) {
	userID := c.GetString("user_id")
	if userID == "" {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "未获取到用户身份"})
		return
	}

	bookID := c.Param("book_id")

	var bookmarks []models.Bookmark
	if err := config.DB.Where("user_id = ? AND book_id = ? AND is_deleted = false", userID, bookID).
		Order("created_at desc").
		Find(&bookmarks).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询失败: " + err.Error()})
		return
	}

	c.JSON(http.StatusOK, bookmarks)
}