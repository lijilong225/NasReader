// handlers/bookmark.go
package handlers

import (
	"net/http"
	"reader-sync/config"
	"reader-sync/models"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

// bookmarkTombstoneTTL 软删除书签的墓碑保留时长。
// 保留期内墓碑会继续同步给其它设备以传播删除；超期后物理清除，避免无限膨胀。
// 离线超过该时长的设备重新同步时，其本地未删除副本可能被复活，这是可接受的取舍。
const bookmarkTombstoneTTL = 30 * 24 * time.Hour

func SyncBookmarks(c *gin.Context) {
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

	err := db.Transaction(func(tx *gorm.DB) error {
		// 先物理清除超过保留期的墓碑，防止软删记录在两端无限累积
		expireBefore := time.Now().Add(-bookmarkTombstoneTTL).UnixMilli()
		if err := tx.Where("user_id = ? AND book_id = ? AND is_deleted = ? AND updated_at < ?",
			userID, req.BookID, true, expireBefore).
			Delete(&models.Bookmark{}).Error; err != nil {
			return err
		}

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
				// 已过保留期的墓碑不再重新入库
				if clientB.IsDeleted && clientB.UpdatedAt < expireBefore {
					continue
				}
				if err := tx.Create(&clientB).Error; err != nil {
					return err
				}
			} else {
				// 直接基于毫秒数值大小进行 LWW 判定
				if clientB.UpdatedAt > serverB.UpdatedAt {
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

	var mergedList []models.Bookmark
	if err := db.Where("user_id = ? AND book_id = ?", userID, req.BookID).
		Order("created_at desc").
		Find(&mergedList).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取书签失败: " + err.Error()})
		return
	}

	c.JSON(http.StatusOK, mergedList)
}

// GetBookmarks 获取用户指定书籍的书签列表（排除已软删除的书签）
func GetBookmarks(c *gin.Context) {
	userID := c.GetString("user_id")
	if userID == "" {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "未获取到用户身份"})
		return
	}

	bookID := c.Param("book_id")
	if bookID == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "缺少 book_id 参数"})
		return
	}

	var bookmarks []models.Bookmark
	if err := config.DB.Where("user_id = ? AND book_id = ? AND is_deleted = ?", userID, bookID, false).
		Order("created_at desc").
		Find(&bookmarks).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取书签失败: " + err.Error()})
		return
	}

	c.JSON(http.StatusOK, bookmarks)
}