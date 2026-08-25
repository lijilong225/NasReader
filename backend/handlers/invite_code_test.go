package handlers

import (
	"os"
	"testing"
)

func TestInitInviteCodeDisabledWhenUnset(t *testing.T) {
	t.Setenv("REGISTRATION_INVITE_CODE", "")
	InitInviteCode()

	if registrationEnabled() {
		t.Fatal("未设置邀请码时注册应关闭")
	}
	if inviteCodeMatches("") {
		t.Fatal("关闭注册时空邀请码不应通过")
	}
	if inviteCodeMatches("anything") {
		t.Fatal("关闭注册时任意邀请码都不应通过")
	}
}

func TestInitInviteCodeTrimsWhitespace(t *testing.T) {
	t.Setenv("REGISTRATION_INVITE_CODE", "  s3cret-invite  ")
	InitInviteCode()

	if !registrationEnabled() {
		t.Fatal("设置邀请码后注册应开启")
	}
	if !inviteCodeMatches("s3cret-invite") {
		t.Fatal("应忽略环境变量首尾空白")
	}
	if !inviteCodeMatches(" s3cret-invite\n") {
		t.Fatal("应忽略请求值首尾空白")
	}
}

func TestInviteCodeMatchesIsExact(t *testing.T) {
	t.Setenv("REGISTRATION_INVITE_CODE", "s3cret-invite")
	InitInviteCode()

	for _, bad := range []string{"", "s3cret", "s3cret-invite-x", "S3CRET-INVITE"} {
		if inviteCodeMatches(bad) {
			t.Fatalf("不应通过: %q", bad)
		}
	}
}

func TestInviteCodeUnsetEnvIsDisabled(t *testing.T) {
	_ = os.Unsetenv("REGISTRATION_INVITE_CODE")
	InitInviteCode()

	if registrationEnabled() {
		t.Fatal("环境变量不存在时注册应关闭")
	}
}
