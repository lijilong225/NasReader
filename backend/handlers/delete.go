// handlers/delete.go
package handlers

import (
	"net/http"
	"reader-sync/config"
	"reader-sync/models"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

// DeleteBookRequest 删除请求结构体
type DeleteBookRequest struct {
	BookID string `json:"book_id" binding:"required"`
	UserID string `json:"user_id"` // 可选，优先使用 Token 中的 user_id
}

// DeleteBookSyncData 接收 book_id，批量删除该用户在云端的阅读进度和书签（不触碰 NAS 物理文件）
func DeleteBookSyncData(c *gin.Context) {
	// 1. 优先从 AuthMiddleware 上下文中提取用户身份
	userID := c.GetString("user_id")
	if userID == "" {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "未获取到用户身份"})
		return
	}

	var req DeleteBookRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求参数无效: " + err.Error()})
		return
	}

	// 如果请求体中传了 user_id 且与 token 不一致，做安全拦截
	if req.UserID != "" && req.UserID != userID {
		c.JSON(http.StatusForbidden, gin.H{"error": "无权操作其他用户的数据"})
		return
	}

	db := config.DB

	// 2. 事务中批量删除阅读进度和书签
	err := db.Transaction(func(tx *gorm.DB) error {
		// 删除阅读进度记录（从书架中移除）
		if err := tx.Where("user_id = ? AND book_id = ?", userID, req.BookID).
			Delete(&models.ReadingProgress{}).Error; err != nil {
			return err
		}

		// 批量删除该书籍相关的全部书签
		if err := tx.Where("user_id = ? AND book_id = ?", userID, req.BookID).
			Delete(&models.Bookmark{}).Error; err != nil {
			return err
		}

		return nil
	})

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "批量删除数据失败: " + err.Error()})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"code":    200,
		"message": "书籍云端进度与书签已彻底删除",
		"book_id": req.BookID,
		"user_id": userID,
	})
}