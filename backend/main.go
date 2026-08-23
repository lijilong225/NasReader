package main

import (
	"log"
	"reader-sync/config"
	"reader-sync/handlers"
	"reader-sync/middleware"

	"github.com/gin-gonic/gin"
)

func main() {
	// 初始化 SQLite 数据库
	config.InitDB()

	r := gin.Default()

	// 允许跨域 (CORS) 中间件
	r.Use(func(c *gin.Context) {
		c.Writer.Header().Set("Access-Control-Allow-Origin", "*")
		c.Writer.Header().Set("Access-Control-Allow-Credentials", "true")
		c.Writer.Header().Set("Access-Control-Allow-Headers", "Content-Type, Content-Length, Accept-Encoding, X-CSRF-Token, Authorization, accept, origin, Cache-Control, X-Requested-With")
		c.Writer.Header().Set("Access-Control-Allow-Methods", "POST, OPTIONS, GET, PUT, DELETE")

		if c.Request.Method == "OPTIONS" {
			c.AbortWithStatus(204)
			return
		}
		c.Next()
	})

	api := r.Group("/api/v1")
	{
		// 开放接口：用户注册与登录
		authGroup := api.Group("/auth")
		{
			authGroup.POST("/register", handlers.Register)
			authGroup.POST("/login", handlers.Login)
		}

		// 受保护接口：需携带 JWT Token
		syncGroup := api.Group("/sync")
		syncGroup.Use(middleware.AuthMiddleware())
		{
			syncGroup.GET("/progress", handlers.GetAllProgress)
			syncGroup.GET("/progress/:book_id", handlers.GetProgress)
			syncGroup.POST("/progress", handlers.SyncProgress)
		}
	}

	// 在受保护的 API 路由组内增加文件相关接口
	fileGroup := api.Group("/files")
	fileGroup.Use(middleware.AuthMiddleware())
	{
    	fileGroup.GET("/browse", handlers.BrowseDirectory)
    	fileGroup.GET("/download", handlers.DownloadFile)
    }

	log.Println("Reader Sync Server started on :8080")
	if err := r.Run(":8080"); err != nil {
		log.Fatalf("Server failed to start: %v", err)
	}
}