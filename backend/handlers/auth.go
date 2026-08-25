package handlers

import (
	"crypto/rand"
	"encoding/hex"
	"net/http"
	"reader-sync/config"
	"reader-sync/middleware"
	"reader-sync/models"
	"time"

	"github.com/gin-gonic/gin"
	"golang.org/x/crypto/bcrypt"
)

// AuthLimiter 限制登录/注册的失败频率：15 分钟内失败 5 次即锁定 15 分钟。
var AuthLimiter = middleware.NewLoginRateLimiter(5, 15*time.Minute, 15*time.Minute)

// dummyPasswordHash 用于用户不存在时的等时比对，抵御用户名枚举。
var dummyPasswordHash, _ = bcrypt.GenerateFromPassword([]byte("dummy-password-for-constant-time"), bcrypt.DefaultCost)

// RegisterRequest 注册时强制更长的密码
type RegisterRequest struct {
	Username string `json:"username" binding:"required,min=3,max=50"`
	Password string `json:"password" binding:"required,min=8"`
}

// AuthRequest 登录用；保持 min=6 以便历史用户仍可登录
type AuthRequest struct {
	Username string `json:"username" binding:"required,min=3,max=50"`
	Password string `json:"password" binding:"required,min=6"`
}

func Register(c *gin.Context) {
	var req RegisterRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	var existing models.User
	if err := config.DB.Where("username = ?", req.Username).First(&existing).Error; err == nil {
		c.JSON(http.StatusConflict, gin.H{"error": "Username already exists"})
		return
	}

	hashedPassword, err := bcrypt.GenerateFromPassword([]byte(req.Password), bcrypt.DefaultCost)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to encrypt password"})
		return
	}

	randomBytes := make([]byte, 16)
	_, _ = rand.Read(randomBytes)
	userID := hex.EncodeToString(randomBytes)

	user := models.User{
		ID:       userID,
		Username: req.Username,
		Password: string(hashedPassword),
	}

	if err := config.DB.Create(&user).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to create user"})
		return
	}

	token, _ := middleware.GenerateToken(user.ID, user.Username)
	c.JSON(http.StatusOK, gin.H{
		"message": "User registered successfully",
		"token":   token,
		"user": gin.H{
			"id":       user.ID,
			"username": user.Username,
		},
	})
}

func Login(c *gin.Context) {
	var req AuthRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	clientKey := c.ClientIP()

	var user models.User
	if err := config.DB.Where("username = ?", req.Username).First(&user).Error; err != nil {
		// 对不存在的用户也做一次哈希比对，避免通过响应耗时枚举用户名
		_ = bcrypt.CompareHashAndPassword(dummyPasswordHash, []byte(req.Password))
		AuthLimiter.RecordFailure(clientKey)
		c.JSON(http.StatusUnauthorized, gin.H{"error": "Invalid username or password"})
		return
	}

	if err := bcrypt.CompareHashAndPassword([]byte(user.Password), []byte(req.Password)); err != nil {
		AuthLimiter.RecordFailure(clientKey)
		c.JSON(http.StatusUnauthorized, gin.H{"error": "Invalid username or password"})
		return
	}

	token, err := middleware.GenerateToken(user.ID, user.Username)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to generate token"})
		return
	}

	AuthLimiter.Reset(clientKey)

	c.JSON(http.StatusOK, gin.H{
		"token": token,
		"user": gin.H{
			"id":       user.ID,
			"username": user.Username,
		},
	})
}