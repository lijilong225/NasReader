// handlers/favorite.go
package handlers

import (
	"net/http"
	"reader-sync/config"
	"reader-sync/models"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

// favoriteTombstoneTTL 取消收藏的墓碑保留时长，需与前端 FavoriteService._tombstoneTtl 保持一致。
// 保留期内墓碑继续下发以传播删除，超期后物理清除。
const favoriteTombstoneTTL = 30 * 24 * time.Hour

// GetFavorites 返回当前用户全部收藏（含保留期内的墓碑，供其它设备传播删除）
func GetFavorites(c *gin.Context) {
	userID := c.GetString("user_id")
	if userID == "" {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "未获取到用户身份"})
		return
	}

	list, err := listFavorites(config.DB, userID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取收藏夹失败: " + err.Error()})
		return
	}

	c.JSON(http.StatusOK, gin.H{"data": list})
}

// SyncFavorites 双向合并收藏夹：按 client_updated_at 做 LWW，返回合并后的全量列表
func SyncFavorites(c *gin.Context) {
	userID := c.GetString("user_id")
	if userID == "" {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "未获取到用户身份"})
		return
	}

	var req models.SyncFavoritesRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求参数无效: " + err.Error()})
		return
	}

	expireBefore := time.Now().Add(-favoriteTombstoneTTL).UnixMilli()

	err := config.DB.Transaction(func(tx *gorm.DB) error {
		if err := tx.Where("user_id = ? AND is_deleted = ? AND client_updated_at < ?",
			userID, true, expireBefore).Delete(&models.Favorite{}).Error; err != nil {
			return err
		}

		for _, item := range req.Favorites {
			if item.BookID == "" {
				continue
			}
			// 已过保留期的墓碑不再重新入库
			if item.IsDeleted && item.ClientUpdatedAt < expireBefore {
				continue
			}

			item.UserID = userID
			if item.ClientUpdatedAt == 0 {
				item.ClientUpdatedAt = item.AddedAt
			}

			// 唯一主键 (user_id, book_id) 保证并发上报不会插出重复行，
			// DO UPDATE 的 WHERE 即 LWW 判定，时间戳不够新时不覆盖服务端记录。
			if err := tx.Clauses(clause.OnConflict{
				Columns: []clause.Column{{Name: "user_id"}, {Name: "book_id"}},
				DoUpdates: clause.Assignments(map[string]interface{}{
					"title":             item.Title,
					"file_name":         item.FileName,
					"remote_path":       item.RemotePath,
					"added_at":          item.AddedAt,
					"client_updated_at": item.ClientUpdatedAt,
					"is_deleted":        item.IsDeleted,
				}),
				Where: clause.Where{Exprs: []clause.Expression{
					clause.Lt{
						Column: clause.Column{Table: clause.CurrentTable, Name: "client_updated_at"},
						Value:  item.ClientUpdatedAt,
					},
				}},
			}).Create(&item).Error; err != nil {
				return err
			}
		}
		return nil
	})

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "收藏夹同步失败: " + err.Error()})
		return
	}

	merged, err := listFavorites(config.DB, userID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取收藏夹失败: " + err.Error()})
		return
	}

	c.JSON(http.StatusOK, gin.H{"data": merged})
}

func listFavorites(db *gorm.DB, userID string) ([]models.Favorite, error) {
	var list []models.Favorite
	err := db.Where("user_id = ?", userID).Order("added_at desc").Find(&list).Error
	if list == nil {
		list = []models.Favorite{}
	}
	return list, err
}
