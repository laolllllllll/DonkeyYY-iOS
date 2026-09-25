#!/bin/bash
# DonkeyYY iOS 一键打包脚本
# 用法: ./build.sh

set -e

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PROJECT_NAME="DonkeyYY"
BUNDLE_ID="com.cor.luoli"
BUILD_DIR="build"
OUTPUT_IPA="${PROJECT_NAME}.ipa"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  DonkeyYY iOS 一键打包${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# 进入脚本所在目录
cd "$(dirname "$0")"

# ========== 1. 检查 Xcode ==========
echo -e "${YELLOW}[1/6] 检查 Xcode...${NC}"
if ! command -v xcodebuild &> /dev/null; then
    echo -e "${RED}错误: 未安装 Xcode，请先从 App Store 安装 Xcode${NC}"
    exit 1
fi
XCODE_VERSION=$(xcodebuild -version | head -1)
echo -e "${GREEN}  ✓ ${XCODE_VERSION}${NC}"

# ========== 2. 检查 XcodeGen ==========
echo -e "${YELLOW}[2/6] 检查 XcodeGen...${NC}"
if ! command -v xcodegen &> /dev/null; then
    echo -e "${YELLOW}  未安装 XcodeGen，正在自动安装...${NC}"
    if command -v brew &> /dev/null; then
        brew install xcodegen
    else
        echo -e "${RED}错误: 未安装 Homebrew，请先安装: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"${NC}"
        exit 1
    fi
fi
XCODEGEN_VERSION=$(xcodegen --version 2>/dev/null || echo "unknown")
echo -e "${GREEN}  ✓ XcodeGen ${XCODEGEN_VERSION}${NC}"

# ========== 3. 清理旧构建 ==========
echo -e "${YELLOW}[3/6] 清理旧构建产物...${NC}"
rm -rf "${BUILD_DIR}"
rm -rf "${PROJECT_NAME}.xcodeproj"
rm -f "${OUTPUT_IPA}"
echo -e "${GREEN}  ✓ 已清理${NC}"

# ========== 4. 生成 Xcode 项目 ==========
echo -e "${YELLOW}[4/6] 生成 Xcode 项目...${NC}"
xcodegen generate
echo -e "${GREEN}  ✓ ${PROJECT_NAME}.xcodeproj 已生成${NC}"

# ========== 5. 编译 Archive ==========
echo -e "${YELLOW}[5/6] 编译 Archive（可能需要几分钟）...${NC}"
xcodebuild \
    -project "${PROJECT_NAME}.xcodeproj" \
    -scheme "${PROJECT_NAME}" \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "${BUILD_DIR}/${PROJECT_NAME}.xcarchive" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    DEVELOPMENT_TEAM="" \
    clean archive \
    2>&1 | tail -5

if [ ! -d "${BUILD_DIR}/${PROJECT_NAME}.xcarchive" ]; then
    echo -e "${RED}错误: Archive 失败${NC}"
    exit 1
fi
echo -e "${GREEN}  ✓ Archive 成功${NC}"

# ========== 6. 打包 IPA ==========
echo -e "${YELLOW}[6/6] 打包 IPA...${NC}"
mkdir -p "${BUILD_DIR}/Payload"
cp -R "${BUILD_DIR}/${PROJECT_NAME}.xcarchive/Products/Applications/${PROJECT_NAME}.app" "${BUILD_DIR}/Payload/"

cd "${BUILD_DIR}"
zip -qr "${OUTPUT_IPA}" Payload
cd ..

cp "${BUILD_DIR}/${OUTPUT_IPA}" "./${OUTPUT_IPA}"

# 同时复制 .app 方便 TrollStore
cp -R "${BUILD_DIR}/${PROJECT_NAME}.xcarchive/Products/Applications/${PROJECT_NAME}.app" "./${PROJECT_NAME}.app"

IPA_SIZE=$(du -h "${OUTPUT_IPA}" | cut -f1)
APP_SIZE=$(du -sh "${PROJECT_NAME}.app" | cut -f1)

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  ✅ 打包完成!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "  IPA 文件:  ${YELLOW}$(pwd)/${OUTPUT_IPA}${NC} (${IPA_SIZE})"
echo -e "  APP 文件:  ${YELLOW}$(pwd)/${PROJECT_NAME}.app${NC} (${APP_SIZE})"
echo ""
echo -e "  Bundle ID: ${BUNDLE_ID}"
echo ""
echo -e "${YELLOW}安装方式:${NC}"
echo -e "  • TrollStore: 直接安装 ${PROJECT_NAME}.app"
echo -e "  • Sideloadly/AltStore: 导入 ${OUTPUT_IPA}"
echo -e "  • 爱思助手: 导入 ${OUTPUT_IPA}"
echo ""
