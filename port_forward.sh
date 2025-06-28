#!/bin/bash

#================================================================
# 通用端口转发管理脚本 (Universal Port Forwarding Manager)
# 版本: 2.1
# 作者: Assistant
# 描述: 基于iptables的智能端口转发管理工具
# 支持: Ubuntu/Debian/CentOS/RHEL等Linux发行版
#================================================================

#================================================================
# 配置区域 - 请根据实际情况修改
#================================================================

# 目标服务器配置（需要被中转的服务器）
TARGET_SERVER_IP="111.xxx.xxx.xxx"          # 例如: "111.xxx.xxx.xxx"
TARGET_SERVER_NAME="德国服务器"           # 例如: "德国服务器"

# 中转服务器配置（当前运行脚本的服务器）
RELAY_SERVER_IP="222.xxx.xxx.xxx"         # 例如: "222.xxx.xxx.xxx" 
RELAY_SERVER_NAME="腾讯云"               # 例如: "腾讯云"

# 规则保存文件路径
RULES_FILE="/etc/iptables/rules.v4"

# 自动分配端口的起始范围（避免与常用端口冲突）
AUTO_PORT_START=40000

#================================================================
# 颜色定义
#================================================================
RED='\033[0;31m'        # 错误信息
GREEN='\033[0;32m'      # 成功信息
YELLOW='\033[1;33m'     # 警告信息
BLUE='\033[0;34m'       # 信息标题
CYAN='\033[0;36m'       # 辅助信息
PURPLE='\033[0;35m'     # 强调信息
NC='\033[0m'            # 无颜色

#================================================================
# 工具函数
#================================================================

# 显示带颜色的消息
log_info() { echo -e "${BLUE}[信息]${NC} $1"; }
log_success() { echo -e "${GREEN}[成功]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[警告]${NC} $1"; }
log_error() { echo -e "${RED}[错误]${NC} $1"; }
log_debug() { echo -e "${CYAN}[调试]${NC} $1"; }

# 检查是否为root用户
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "此脚本需要root权限运行"
        log_info "请使用: sudo $0 或切换到root用户"
        exit 1
    fi
}

# 检查配置是否完整
check_config() {
    if [ "$TARGET_SERVER_IP" = "目标服务器IP" ] || [ -z "$TARGET_SERVER_IP" ]; then
        log_error "请先配置目标服务器IP"
        log_info "编辑脚本，修改 TARGET_SERVER_IP 变量"
        exit 1
    fi
    
    if [ "$RELAY_SERVER_IP" = "中转服务器IP" ] || [ -z "$RELAY_SERVER_IP" ]; then
        log_error "请先配置中转服务器IP"
        log_info "编辑脚本，修改 RELAY_SERVER_IP 变量"
        exit 1
    fi
}

# 验证IP地址格式
validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    else
        return 1
    fi
}

# 验证端口号
validate_port() {
    local port=$1
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    else
        return 1
    fi
}

# 检查系统依赖
check_dependencies() {
    local missing_deps=()
    
    # 检查必需的命令
    local required_commands=("iptables" "ss" "netstat")
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_error "缺少必需的命令: ${missing_deps[*]}"
        log_info "请安装相应的软件包"
        log_info "Ubuntu/Debian: apt install iptables iproute2 net-tools"
        log_info "CentOS/RHEL: yum install iptables iproute net-tools"
        exit 1
    fi
}

# 启用IP转发
enable_ip_forward() {
    # 检查IP转发是否已启用
    if [ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ]; then
        log_debug "IP转发已启用"
        return 0
    fi
    
    log_info "启用IP转发..."
    
    # 临时启用
    echo 1 > /proc/sys/net/ipv4/ip_forward
    
    # 永久启用
    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
        log_success "IP转发已永久启用"
    fi
    
    # 使配置生效
    sysctl -p >/dev/null 2>&1
}

#================================================================
# 端口检测函数
#================================================================

# 检查端口是否被系统进程占用
check_port_in_use() {
    local port=$1
    
    # 使用ss命令检查端口监听状态
    if ss -tulpn 2>/dev/null | grep -q ":$port "; then
        return 0  # 端口被占用
    fi
    
    # 备用检查方法（使用netstat）
    if netstat -tulpn 2>/dev/null | grep -q ":$port "; then
        return 0  # 端口被占用
    fi
    
    return 1  # 端口可用
}

# 检查端口是否已有转发规则
check_forward_exists() {
    local relay_port=$1
    iptables -t nat -L PREROUTING -n 2>/dev/null | grep -q "dpt:$relay_port.*to:$TARGET_SERVER_IP"
}

# 获取端口占用的详细信息
get_port_usage_detail() {
    local port=$1
    local details=()
    
    # 检查系统进程占用
    local process_info=$(ss -tulpn 2>/dev/null | grep ":$port " | head -5)
    if [ -n "$process_info" ]; then
        details+=("系统占用")
        while IFS= read -r line; do
            details+=("  $line")
        done <<< "$process_info"
    fi
    
    # 检查转发规则占用
    local forward_info=$(iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null | grep "dpt:$port")
    if [ -n "$forward_info" ]; then
        details+=("转发占用")
        while IFS= read -r line; do
            details+=("  $line")
        done <<< "$forward_info"
    fi
    
    # 输出详情
    if [ ${#details[@]} -gt 0 ]; then
        printf '%s\n' "${details[@]}"
        return 1  # 端口被占用
    else
        echo "端口可用"
        return 0  # 端口可用
    fi
}

# 综合检查端口可用性
check_port_available() {
    local port=$1
    local issues=()
    
    # 检查系统占用
    if check_port_in_use "$port"; then
        issues+=("system")
    fi
    
    # 检查转发规则
    if check_forward_exists "$port"; then
        issues+=("forward")
    fi
    
    if [ ${#issues[@]} -eq 0 ]; then
        echo "available"
        return 0
    else
        echo "${issues[*]}"
        return 1
    fi
}

# 查找可用端口
find_available_port() {
    local start_port=${1:-$AUTO_PORT_START}
    local max_attempts=${2:-1000}
    local attempt=0
    
    log_info "从端口 $start_port 开始查找可用端口..."
    
    for ((port=$start_port; port<=65535 && attempt<$max_attempts; port++)); do
        ((attempt++))
        
        # 检查端口可用性
        local status=$(check_port_available "$port")
        
        if [ "$status" = "available" ]; then
            echo "$port"
            return 0
        fi
        
        # 显示搜索进度
        if [ $((attempt % 100)) -eq 0 ]; then
            log_debug "已检查 $attempt 个端口，当前检查: $port"
        fi
    done
    
    log_error "在 $max_attempts 次尝试内未找到可用端口"
    return 1
}

#================================================================
# 转发规则管理函数
#================================================================

# 添加端口转发规则
add_port_forward() {
    local target_port=$1      # 目标服务器端口
    local relay_port=$2       # 中转服务器端口
    local auto_assign=${3:-false}  # 是否自动分配端口
    
    # 参数验证
    if ! validate_port "$target_port"; then
        log_error "无效的目标端口: $target_port"
        return 1
    fi
    
    # 如果未指定中转端口，默认使用相同端口
    if [ -z "$relay_port" ]; then
        relay_port=$target_port
    elif ! validate_port "$relay_port"; then
        log_error "无效的中转端口: $relay_port"
        return 1
    fi
    
    # 检查中转端口可用性
    local port_status=$(check_port_available "$relay_port")
    
    if [ "$port_status" != "available" ]; then
        log_warning "中转端口 $relay_port 不可用:"
        get_port_usage_detail "$relay_port" | while IFS= read -r line; do
            echo "  $line"
        done
        
        # 如果启用自动分配，查找可用端口
        if [ "$auto_assign" = "true" ]; then
            log_info "自动查找可用端口..."
            local new_port=$(find_available_port "$relay_port")
            if [ $? -eq 0 ] && [ -n "$new_port" ]; then
                relay_port=$new_port
                log_success "自动分配端口: $relay_port"
            else
                log_error "无法找到可用端口"
                return 1
            fi
        else
            log_info "建议解决方案:"
            log_info "  1. 使用自动分配: $0 auto $target_port"
            log_info "  2. 查找可用端口: $0 find-free $relay_port"
            log_info "  3. 指定其他端口: $0 add $target_port <其他端口>"
            return 1
        fi
    fi
    
    # 确保IP转发已启用
    enable_ip_forward
    
    # 添加iptables规则
    log_info "添加转发规则: $RELAY_SERVER_IP:$relay_port → $TARGET_SERVER_IP:$target_port"
    
    # PREROUTING规则：将进入中转服务器的流量转发到目标服务器
    if ! iptables -t nat -A PREROUTING -p tcp --dport "$relay_port" -j DNAT --to-destination "$TARGET_SERVER_IP:$target_port"; then
        log_error "添加PREROUTING规则失败"
        return 1
    fi
    
    # FORWARD规则：允许转发的流量通过
    if ! iptables -A FORWARD -p tcp --dport "$target_port" -j ACCEPT; then
        log_error "添加FORWARD规则失败"
        # 清理已添加的PREROUTING规则
        iptables -t nat -D PREROUTING -p tcp --dport "$relay_port" -j DNAT --to-destination "$TARGET_SERVER_IP:$target_port" 2>/dev/null
        return 1
    fi
    
    # POSTROUTING规则：确保回程流量正确路由
    if ! iptables -t nat -C POSTROUTING -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -j MASQUERADE
    fi
    
    # 验证规则是否添加成功
    if check_forward_exists "$relay_port"; then
        log_success "端口转发添加成功!"
        echo ""
        log_info "转发配置:"
        echo "  ${TARGET_SERVER_NAME}: $TARGET_SERVER_IP:$target_port"
        echo "  ${RELAY_SERVER_NAME}访问: $RELAY_SERVER_IP:$relay_port"
        echo ""
        
        # 如果端口不同，提供配置修改建议
        if [ "$target_port" != "$relay_port" ]; then
            log_info "配置修改建议:"
            echo "  原配置: @$TARGET_SERVER_IP:$target_port"
            echo "  新配置: @$RELAY_SERVER_IP:$relay_port"
        fi
        
        return 0
    else
        log_error "转发规则验证失败"
        return 1
    fi
}

# 修改端口转发规则
modify_port_forward() {
    local old_relay_port=$1
    local new_target_port=$2
    local new_relay_port=$3
    local force=${4:-false}
    
    # 参数验证
    if ! validate_port "$old_relay_port"; then
        log_error "无效的原中转端口: $old_relay_port"
        return 1
    fi
    
    # 检查原规则是否存在
    if ! check_forward_exists "$old_relay_port"; then
        log_error "中转端口 $old_relay_port 没有转发规则"
        log_info "使用 '$0 list' 查看现有规则"
        return 1
    fi
    
    # 获取原规则信息
    local rule_info=$(iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null | grep "dpt:$old_relay_port.*to:$TARGET_SERVER_IP")
    local old_target_port=$(echo "$rule_info" | grep -o "to:$TARGET_SERVER_IP:[0-9]*" | cut -d':' -f3)
    
    log_info "当前规则: $RELAY_SERVER_IP:$old_relay_port → $TARGET_SERVER_IP:$old_target_port"
    
    # 验证新参数
    if [ -n "$new_target_port" ] && ! validate_port "$new_target_port"; then
        log_error "无效的新目标端口: $new_target_port"
        return 1
    fi
    
    if [ -n "$new_relay_port" ] && ! validate_port "$new_relay_port"; then
        log_error "无效的新中转端口: $new_relay_port"
        return 1
    fi
    
    # 设置默认值
    local final_target_port=${new_target_port:-$old_target_port}
    local final_relay_port=${new_relay_port:-$old_relay_port}
    
    # 检查是否有实际变化
    if [ "$final_target_port" = "$old_target_port" ] && [ "$final_relay_port" = "$old_relay_port" ]; then
        log_warning "新配置与原配置相同，无需修改"
        return 0
    fi
    
    # 如果中转端口有变化，检查新端口可用性
    if [ "$final_relay_port" != "$old_relay_port" ]; then
        local port_status=$(check_port_available "$final_relay_port")
        
        if [ "$port_status" != "available" ] && [ "$force" != "true" ]; then
            log_error "新中转端口 $final_relay_port 不可用:"
            get_port_usage_detail "$final_relay_port" | while IFS= read -r line; do
                echo "  $line"
            done
            log_info "使用 --force 参数强制修改，或选择其他端口"
            return 1
        fi
    fi
    
    log_info "修改转发规则:"
    echo "  原配置: $RELAY_SERVER_IP:$old_relay_port → $TARGET_SERVER_IP:$old_target_port"
    echo "  新配置: $RELAY_SERVER_IP:$final_relay_port → $TARGET_SERVER_IP:$final_target_port"
    
    # 删除原规则
    log_debug "删除原转发规则..."
    if ! iptables -t nat -D PREROUTING -p tcp --dport "$old_relay_port" -j DNAT --to-destination "$TARGET_SERVER_IP:$old_target_port" 2>/dev/null; then
        log_error "删除原PREROUTING规则失败"
        return 1
    fi
    
    if ! iptables -D FORWARD -p tcp --dport "$old_target_port" -j ACCEPT 2>/dev/null; then
        log_warning "删除原FORWARD规则失败（可能与其他规则共享）"
    fi
    
    # 添加新规则
    log_debug "添加新转发规则..."
    if ! iptables -t nat -A PREROUTING -p tcp --dport "$final_relay_port" -j DNAT --to-destination "$TARGET_SERVER_IP:$final_target_port"; then
        log_error "添加新PREROUTING规则失败"
        # 尝试恢复原规则
        log_warning "尝试恢复原规则..."
        iptables -t nat -A PREROUTING -p tcp --dport "$old_relay_port" -j DNAT --to-destination "$TARGET_SERVER_IP:$old_target_port" 2>/dev/null
        return 1
    fi
    
    if ! iptables -A FORWARD -p tcp --dport "$final_target_port" -j ACCEPT; then
        log_warning "添加新FORWARD规则失败"
    fi
    
    # 验证新规则
    if check_forward_exists "$final_relay_port"; then
        log_success "转发规则修改成功!"
        echo ""
        log_info "新的转发配置:"
        echo "  ${TARGET_SERVER_NAME}: $TARGET_SERVER_IP:$final_target_port"
        echo "  ${RELAY_SERVER_NAME}访问: $RELAY_SERVER_IP:$final_relay_port"
        
        # 提供配置修改建议
        if [ "$old_relay_port" != "$final_relay_port" ]; then
            echo ""
            log_info "客户端配置需要更新:"
            echo "  原配置: @$RELAY_SERVER_IP:$old_relay_port"
            echo "  新配置: @$RELAY_SERVER_IP:$final_relay_port"
        fi
        
        return 0
    else
        log_error "规则修改验证失败"
        return 1
    fi
}

# 交互式修改转发规则
interactive_modify() {
    local relay_port=$1
    
    if ! validate_port "$relay_port"; then
        log_error "无效的中转端口: $relay_port"
        return 1
    fi
    
    # 检查规则是否存在
    if ! check_forward_exists "$relay_port"; then
        log_error "中转端口 $relay_port 没有转发规则"
        return 1
    fi
    
    # 获取当前规则信息
    local rule_info=$(iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null | grep "dpt:$relay_port.*to:$TARGET_SERVER_IP")
    local current_target_port=$(echo "$rule_info" | grep -o "to:$TARGET_SERVER_IP:[0-9]*" | cut -d':' -f3)
    
    echo -e "${BLUE}=== 修改转发规则 ===${NC}"
    echo ""
    echo -e "${YELLOW}当前配置:${NC}"
    echo "  中转端口: $relay_port"
    echo "  目标端口: $current_target_port"
    echo "  映射关系: $RELAY_SERVER_IP:$relay_port → $TARGET_SERVER_IP:$current_target_port"
    echo ""
    
    # 询问修改选项
    echo -e "${YELLOW}修改选项:${NC}"
    echo "  1. 只修改目标端口"
    echo "  2. 只修改中转端口"
    echo "  3. 同时修改目标端口和中转端口"
    echo "  4. 取消修改"
    echo ""
    
    read -p "请选择修改选项 (1-4): " -r choice
    
    local new_target_port=""
    local new_relay_port=""
    
    case "$choice" in
        1)
            read -p "请输入新的目标端口 [$current_target_port]: " -r new_target_port
            if [ -z "$new_target_port" ]; then
                new_target_port=$current_target_port
            fi
            ;;
        2)
            read -p "请输入新的中转端口 [$relay_port]: " -r new_relay_port
            if [ -z "$new_relay_port" ]; then
                new_relay_port=$relay_port
            fi
            ;;
        3)
            read -p "请输入新的目标端口 [$current_target_port]: " -r new_target_port
            read -p "请输入新的中转端口 [$relay_port]: " -r new_relay_port
            
            if [ -z "$new_target_port" ]; then
                new_target_port=$current_target_port
            fi
            if [ -z "$new_relay_port" ]; then
                new_relay_port=$relay_port
            fi
            ;;
        4)
            log_info "修改已取消"
            return 0
            ;;
        *)
            log_error "无效的选择"
            return 1
            ;;
    esac
    
    # 确认修改
    echo ""
    echo -e "${YELLOW}修改确认:${NC}"
    echo "  原配置: $RELAY_SERVER_IP:$relay_port → $TARGET_SERVER_IP:$current_target_port"
    echo "  新配置: $RELAY_SERVER_IP:${new_relay_port:-$relay_port} → $TARGET_SERVER_IP:${new_target_port:-$current_target_port}"
    echo ""
    
    read -p "确认修改? (y/N): " -r confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        log_info "修改已取消"
        return 0
    fi
    
    # 执行修改
    modify_port_forward "$relay_port" "$new_target_port" "$new_relay_port"
}

# 删除端口转发规则
remove_port_forward() {
    local relay_port=$1
    local confirm=${2:-true}
    
    if ! validate_port "$relay_port"; then
        log_error "无效的端口号: $relay_port"
        return 1
    fi
    
    # 查找对应的转发规则
    local rule_info=$(iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null | grep "dpt:$relay_port.*to:$TARGET_SERVER_IP")
    
    if [ -z "$rule_info" ]; then
        log_warning "端口 $relay_port 没有转发规则"
        return 1
    fi
    
    # 解析目标端口
    local target_port=$(echo "$rule_info" | grep -o "to:$TARGET_SERVER_IP:[0-9]*" | cut -d':' -f3)
    
    # 显示要删除的规则信息
    log_info "准备删除转发规则: $RELAY_SERVER_IP:$relay_port → $TARGET_SERVER_IP:$target_port"
    
    # 确认删除（如果需要）
    if [ "$confirm" = "true" ]; then
        read -p "确认删除此转发规则? (y/N): " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "删除已取消"
            return 0
        fi
    fi
    
    # 删除PREROUTING规则
    if iptables -t nat -D PREROUTING -p tcp --dport "$relay_port" -j DNAT --to-destination "$TARGET_SERVER_IP:$target_port" 2>/dev/null; then
        log_debug "PREROUTING规则删除成功"
    else
        log_warning "PREROUTING规则删除失败或不存在"
    fi
    
    # 删除FORWARD规则
    if iptables -D FORWARD -p tcp --dport "$target_port" -j ACCEPT 2>/dev/null; then
        log_debug "FORWARD规则删除成功"
    else
        log_warning "FORWARD规则删除失败或不存在"
    fi
    
    # 验证删除结果
    if ! check_forward_exists "$relay_port"; then
        log_success "端口转发删除成功"
        return 0
    else
        log_error "端口转发删除失败"
        return 1
    fi
}

# 列出转发规则（增强版）
list_port_forwards() {
    local search_port=$1
    
    if [ -n "$search_port" ]; then
        echo -e "${BLUE}=== 端口 $search_port 详细信息 ===${NC}"
        
        # 查找转发规则
        local rule_info=$(iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null | grep "dpt:$search_port.*to:$TARGET_SERVER_IP")
        
        if [ -n "$rule_info" ]; then
            echo -e "${GREEN}转发规则:${NC}"
            echo "$rule_info"
            
            local target_port=$(echo "$rule_info" | grep -o "to:$TARGET_SERVER_IP:[0-9]*" | cut -d':' -f3)
            echo -e "${CYAN}映射关系:${NC} $RELAY_SERVER_IP:$search_port → $TARGET_SERVER_IP:$target_port"
        else
            echo -e "${YELLOW}没有找到转发规则${NC}"
        fi
        
        # 检查端口占用情况
        echo ""
        echo -e "${CYAN}端口占用情况:${NC}"
        get_port_usage_detail "$search_port"
        
    else
        echo -e "${BLUE}=== 所有端口转发规则 ===${NC}"
        local total_rules=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep -c "to:$TARGET_SERVER_IP")
        echo "转发规则总数: $total_rules"
        echo ""
        
        if [ "$total_rules" -eq 0 ]; then
            log_warning "没有找到任何转发规则"
            return 0
        fi
        
        echo -e "${YELLOW}转发映射列表:${NC}"
        printf "%-6s %-15s %-15s %-10s\n" "序号" "${RELAY_SERVER_NAME}端口" "${TARGET_SERVER_NAME}端口" "状态"
        echo "------------------------------------------------"
        
        local count=1
        iptables -t nat -L PREROUTING -n 2>/dev/null | grep "to:$TARGET_SERVER_IP" | head -20 | while IFS= read -r line; do
            local relay_port=$(echo "$line" | grep -o "dpt:[0-9]*" | cut -d':' -f2)
            local target_port=$(echo "$line" | grep -o "to:$TARGET_SERVER_IP:[0-9]*" | cut -d':' -f3)
            
            local status="正常"
            if ! check_port_in_use "$relay_port"; then
                status="未占用"
            fi
            
            printf "%-6s %-15s %-15s %-10s\n" "$count" "$relay_port" "$target_port" "$status"
            ((count++))
        done
        
        if [ "$total_rules" -gt 20 ]; then
            echo "..."
            echo "（显示前20条，总共 $total_rules 条规则）"
            log_info "使用 '$0 list <端口>' 查看特定端口详情"
        fi
    fi
}

# 测试端口转发
test_port_forward() {
    local relay_port=$1
    
    if ! validate_port "$relay_port"; then
        log_error "无效的端口号: $relay_port"
        return 1
    fi
    
    log_info "测试端口 $relay_port 转发状态..."
    
    # 检查转发规则是否存在
    if ! check_forward_exists "$relay_port"; then
        log_error "端口 $relay_port 没有配置转发规则"
        return 1
    fi
    
    # 获取目标端口
    local rule_info=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep "dpt:$relay_port.*to:$TARGET_SERVER_IP")
    local target_port=$(echo "$rule_info" | grep -o "to:$TARGET_SERVER_IP:[0-9]*" | cut -d':' -f3)
    
    echo ""
    log_info "转发配置: $RELAY_SERVER_IP:$relay_port → $TARGET_SERVER_IP:$target_port"
    
    # 测试本地端口连通性
    log_info "测试中转服务器端口连通性..."
    if timeout 3 bash -c "echo > /dev/tcp/127.0.0.1/$relay_port" 2>/dev/null; then
        log_success "中转端口 $relay_port 可以连接"
    else
        log_warning "中转端口 $relay_port 连接失败（目标服务可能未启动）"
    fi
    
    # 测试到目标服务器的连通性
    log_info "测试到目标服务器的连通性..."
    if timeout 3 bash -c "echo > /dev/tcp/$TARGET_SERVER_IP/$target_port" 2>/dev/null; then
        log_success "目标服务器 $TARGET_SERVER_IP:$target_port 可以连接"
    else
        log_warning "目标服务器 $TARGET_SERVER_IP:$target_port 连接失败"
    fi
    
    echo ""
    log_info "测试完成。如果连接失败，请检查:"
    echo "  1. 目标服务器 $TARGET_SERVER_IP 是否可达"
    echo "  2. 目标端口 $target_port 上是否有服务运行"
    echo "  3. 防火墙设置是否正确"
}

#================================================================
# 规则管理函数
#================================================================

# 保存iptables规则
save_rules() {
    log_info "保存iptables规则..."
    
    # 创建目录
    mkdir -p "$(dirname "$RULES_FILE")"
    
    # 保存规则
    if iptables-save > "$RULES_FILE" 2>/dev/null; then
        log_success "规则已保存到 $RULES_FILE"
        log_info "重启后将自动加载这些规则"
        
        # 安装iptables-persistent（如果可用）
        if command -v apt-get >/dev/null 2>&1; then
            if ! dpkg -l | grep -q iptables-persistent; then
                log_info "建议安装 iptables-persistent 以确保规则永久生效:"
                log_info "  sudo apt install iptables-persistent"
            fi
        fi
    else
        log_error "保存规则失败"
        return 1
    fi
}

# 恢复iptables规则
restore_rules() {
    if [ ! -f "$RULES_FILE" ]; then
        log_error "规则文件 $RULES_FILE 不存在"
        return 1
    fi
    
    log_info "恢复iptables规则..."
    
    if iptables-restore < "$RULES_FILE" 2>/dev/null; then
        log_success "规则已从 $RULES_FILE 恢复"
    else
        log_error "恢复规则失败"
        return 1
    fi
}

# 备份当前规则
backup_rules() {
    local backup_file="/root/iptables_backup_$(date +%Y%m%d_%H%M%S).txt"
    
    log_info "备份当前iptables规则..."
    
    if iptables-save > "$backup_file" 2>/dev/null; then
        log_success "规则已备份到 $backup_file"
    else
        log_error "备份规则失败"
        return 1
    fi
}

# 显示系统状态
show_status() {
    echo -e "${BLUE}=== 端口转发系统状态 ===${NC}"
    echo ""
    
    # 显示配置信息
    echo -e "${YELLOW}配置信息:${NC}"
    echo "  目标服务器: $TARGET_SERVER_NAME ($TARGET_SERVER_IP)"
    echo "  中转服务器: $RELAY_SERVER_NAME ($RELAY_SERVER_IP)"
    echo ""
    
    # 显示系统状态
    echo -e "${YELLOW}系统状态:${NC}"
    echo "  IP转发状态: $([ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ] && echo -e "${GREEN}已启用${NC}" || echo -e "${RED}未启用${NC}")"
    
    local total_rules=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep -c "to:$TARGET_SERVER_IP")
    echo "  转发规则数量: $total_rules"
    
    # 检查重要端口状态
    echo ""
    echo -e "${YELLOW}重要端口状态:${NC}"
    local important_ports=(22 80 443 3389 8080 8443)
    
    for port in "${important_ports[@]}"; do
        local status=$(check_port_available "$port")
        if [ "$status" = "available" ]; then
            echo -e "  端口 $port: ${GREEN}可用${NC}"
        else
            echo -e "  端口 $port: ${RED}占用${NC} ($status)"
        fi
    done
    
    # 显示最近的转发规则
    if [ "$total_rules" -gt 0 ]; then
        echo ""
        echo -e "${YELLOW}最近的转发规则:${NC}"
        iptables -t nat -L PREROUTING -n 2>/dev/null | grep "to:$TARGET_SERVER_IP" | head -5 | while IFS= read -r line; do
            local relay_port=$(echo "$line" | grep -o "dpt:[0-9]*" | cut -d':' -f2)
            local target_port=$(echo "$line" | grep -o "to:$TARGET_SERVER_IP:[0-9]*" | cut -d':' -f3)
            echo "  $relay_port → $target_port"
        done
    fi
}

# 显示连接信息
show_connection_info() {
    echo -e "${BLUE}=== 连接信息 ===${NC}"
    echo ""
    
    echo -e "${YELLOW}服务器信息:${NC}"
    echo "  ${TARGET_SERVER_NAME}: $TARGET_SERVER_IP"
    echo "  ${RELAY_SERVER_NAME}: $RELAY_SERVER_IP"
    echo ""
    
    echo -e "${YELLOW}使用说明:${NC}"
    echo "  1. 原始连接: 客户端 → $TARGET_SERVER_IP:端口"
    echo "  2. 中转连接: 客户端 → $RELAY_SERVER_IP:端口 → $TARGET_SERVER_IP:端口"
    echo ""
    
    echo -e "${YELLOW}配置修改:${NC}"
    echo "  将原配置中的 $TARGET_SERVER_IP 替换为 $RELAY_SERVER_IP"
    echo "  如果端口有变化，同时更新端口号"
    echo ""
    
    echo -e "${YELLOW}常用命令:${NC}"
    echo "  添加转发: $0 add <目标端口> [中转端口]"
    echo "  自动分配: $0 auto <目标端口>"
    echo "  修改规则: $0 modify <中转端口> [新目标端口] [新中转端口]"
    echo "  查看状态: $0 status"
    echo "  测试连接: $0 test <中转端口>"
}

# 显示当前配置
show_config() {
    echo -e "${BLUE}=== 当前配置 ===${NC}"
    echo ""
    echo -e "${YELLOW}服务器配置:${NC}"
    echo "  目标服务器IP: $TARGET_SERVER_IP"
    echo "  目标服务器名称: $TARGET_SERVER_NAME"
    echo "  中转服务器IP: $RELAY_SERVER_IP"
    echo "  中转服务器名称: $RELAY_SERVER_NAME"
    echo ""
    echo -e "${YELLOW}系统配置:${NC}"
    echo "  规则保存路径: $RULES_FILE"
    echo "  自动端口起始: $AUTO_PORT_START"
    echo ""
    echo -e "${YELLOW}修改配置:${NC}"
    echo "  编辑脚本文件，修改顶部配置区域的变量"
    echo "  或复制脚本到新文件并修改配置"
}

# 批量添加端口范围
add_port_range() {
    local start_port=$1
    local end_port=$2
    
    if ! validate_port "$start_port" || ! validate_port "$end_port"; then
        log_error "无效的端口范围: $start_port-$end_port"
        return 1
    fi
    
    if [ "$start_port" -gt "$end_port" ]; then
        log_error "起始端口不能大于结束端口"
        return 1
    fi
    
    local total_ports=$((end_port - start_port + 1))
    if [ "$total_ports" -gt 1000 ]; then
        log_warning "端口范围过大($total_ports个端口)，建议分批处理"
        read -p "是否继续？(y/N): " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "操作已取消"
            return 1
        fi
    fi
    
    log_info "批量添加端口范围: $start_port-$end_port ($total_ports个端口)"
    
    local success_count=0
    local fail_count=0
    
    for port in $(seq "$start_port" "$end_port"); do
        if add_port_forward "$port" "$port" false >/dev/null 2>&1; then
            ((success_count++))
        else
            ((fail_count++))
        fi
        
        # 显示进度
        local current=$((port - start_port + 1))
        echo -ne "\r${CYAN}进度: $current/$total_ports (成功: $success_count, 失败: $fail_count)${NC}"
    done
    
    echo ""
    log_success "批量添加完成: 成功 $success_count 个，失败 $fail_count 个"
    
    if [ "$fail_count" -gt 0 ]; then
        log_info "失败的端口可能已被占用或已有转发规则"
    fi
}

# 清理和维护功能
cleanup_rules() {
    log_info "检查转发规则完整性..."
    
    local total_prerouting=0
    local total_forward=0
    local orphan_rules=0
    
    # 统计PREROUTING规则
    total_prerouting=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep -c "to:$TARGET_SERVER_IP")
    
    # 统计FORWARD规则（这个比较复杂，简化处理）
    total_forward=$(iptables -L FORWARD -n 2>/dev/null | grep -c "ACCEPT")
    
    log_info "规则统计:"
    echo "  PREROUTING规则: $total_prerouting"
    echo "  FORWARD规则: $total_forward"
    
    # 检查重复规则
    log_info "检查重复规则..."
    local duplicate_count=0
    
    # 获取所有转发端口并检查重复
    local ports=($(iptables -t nat -L PREROUTING -n 2>/dev/null | grep "to:$TARGET_SERVER_IP" | grep -o "dpt:[0-9]*" | cut -d':' -f2 | sort))
    local prev_port=""
    
    for port in "${ports[@]}"; do
        if [ "$port" = "$prev_port" ]; then
            ((duplicate_count++))
            log_warning "发现重复端口: $port"
        fi
        prev_port="$port"
    done
    
    if [ "$duplicate_count" -eq 0 ]; then
        log_success "未发现重复规则"
    else
        log_warning "发现 $duplicate_count 个重复规则，建议手动清理"
    fi
    
    log_success "规则检查完成"
}

#================================================================
# 主程序和命令行接口
#================================================================

# 显示使用帮助
show_usage() {
    echo -e "${BLUE}=== 通用端口转发管理工具 ===${NC}"
    echo ""
    echo -e "${PURPLE}当前配置:${NC}"
    echo "  目标服务器: $TARGET_SERVER_NAME ($TARGET_SERVER_IP)"
    echo "  中转服务器: $RELAY_SERVER_NAME ($RELAY_SERVER_IP)"
    echo ""
    echo "用法: $0 {命令} [参数]"
    echo ""
    echo -e "${YELLOW}端口转发命令:${NC}"
    echo "  add <目标端口> [中转端口]        添加端口转发（可指定不同端口）"
    echo "  auto <目标端口>                 自动分配中转端口"
    echo "  map <目标端口> <中转端口>       映射到指定中转端口"
    echo "  modify <中转端口> [新目标端口] [新中转端口]  修改现有转发规则"
    echo "  edit <中转端口>                 交互式修改转发规则"
    echo "  remove <中转端口>               删除端口转发"
    echo "  range <起始端口> <结束端口>     批量添加相同端口转发"
    echo ""
    echo -e "${YELLOW}查看和测试命令:${NC}"
    echo "  list [端口]                     显示转发规则列表"
    echo "  status                          显示系统状态"
    echo "  test <中转端口>                 测试端口转发"
    echo "  check <端口>                    检查端口占用情况"
    echo "  find-free [起始端口]            查找可用端口"
    echo ""
    echo -e "${YELLOW}管理命令:${NC}"
    echo "  save                            保存当前规则"
    echo "  restore                         恢复保存的规则"
    echo "  backup                          备份当前规则"
    echo "  info                            显示连接信息"
    echo "  config                          显示当前配置"
    echo "  cleanup                         检查规则完整性"
    echo ""
    echo -e "${YELLOW}使用示例:${NC}"
    echo "  $0 add 3389                     转发3389端口（相同端口）"
    echo "  $0 add 3389 13389               目标3389端口映射到中转13389端口"
    echo "  $0 auto 3389                    自动为3389端口分配中转端口"
    echo "  $0 map 22 2222                  SSH端口映射"
    echo "  $0 modify 13389 3390            修改13389端口的目标端口为3390"
    echo "  $0 modify 13389 3390 23389      修改目标端口为3390，中转端口为23389"
    echo "  $0 edit 13389                   交互式修改13389端口的转发规则"
    echo "  $0 test 13389                   测试13389端口转发"
    echo "  $0 find-free 40000              从40000开始查找可用端口"
    echo ""
    echo -e "${YELLOW}配置文件:${NC}"
    echo "  编辑脚本顶部的配置区域来设置目标服务器和中转服务器信息"
}

#================================================================
# 主程序入口
#================================================================

# 主函数
main() {
    # 检查运行权限
    check_root
    
    # 检查系统依赖
    check_dependencies
    
    # 检查配置
    check_config
    
    # 验证IP地址格式
    if ! validate_ip "$TARGET_SERVER_IP"; then
        log_error "无效的目标服务器IP地址: $TARGET_SERVER_IP"
        exit 1
    fi
    
    if ! validate_ip "$RELAY_SERVER_IP"; then
        log_error "无效的中转服务器IP地址: $RELAY_SERVER_IP"
        exit 1
    fi
    
    # 解析命令行参数
    case "${1:-help}" in
        "add")
            if [ -z "$2" ]; then
                log_error "请指定目标端口号"
                show_usage
                exit 1
            fi
            add_port_forward "$2" "$3"
            ;;
        "auto")
            if [ -z "$2" ]; then
                log_error "请指定目标端口号"
                show_usage
                exit 1
            fi
            add_port_forward "$2" "" true
            ;;
        "map")
            if [ -z "$2" ] || [ -z "$3" ]; then
                log_error "请指定目标端口和中转端口"
                echo "用法: $0 map <目标端口> <中转端口>"
                exit 1
            fi
            add_port_forward "$2" "$3"
            ;;
        "modify")
            if [ -z "$2" ]; then
                log_error "请指定要修改的中转端口号"
                echo "用法: $0 modify <中转端口> [新目标端口] [新中转端口]"
                exit 1
            fi
            # 检查是否有--force参数
            local force="false"
            if [[ "$*" == *"--force"* ]]; then
                force="true"
            fi
            modify_port_forward "$2" "$3" "$4" "$force"
            ;;
        "edit")
            if [ -z "$2" ]; then
                log_error "请指定要修改的中转端口号"
                echo "用法: $0 edit <中转端口>"
                exit 1
            fi
            interactive_modify "$2"
            ;;
        "remove")
            if [ -z "$2" ]; then
                log_error "请指定要删除的中转端口号"
                exit 1
            fi
            # 检查是否有--force参数（跳过确认）
            local force_remove="false"
            if [[ "$*" == *"--force"* ]]; then
                force_remove="true"
            fi
            remove_port_forward "$2" "$([ "$force_remove" = "true" ] && echo "false" || echo "true")"
            ;;
        "range")
            if [ -z "$2" ] || [ -z "$3" ]; then
                log_error "请指定端口范围"
                echo "用法: $0 range <起始端口> <结束端口>"
                exit 1
            fi
            add_port_range "$2" "$3"
            ;;
        "list")
            list_port_forwards "$2"
            ;;
        "status")
            show_status
            ;;
        "test")
            if [ -z "$2" ]; then
                log_error "请指定要测试的中转端口号"
                exit 1
            fi
            test_port_forward "$2"
            ;;
        "check")
            if [ -z "$2" ]; then
                log_error "请指定要检查的端口号"
                exit 1
            fi
            echo -e "${BLUE}=== 端口 $2 占用情况 ===${NC}"
            get_port_usage_detail "$2"
            ;;
        "find-free")
            local found_port=$(find_available_port "$2")
            if [ $? -eq 0 ]; then
                log_success "找到可用端口: $found_port"
            fi
            ;;
        "save")
            save_rules
            ;;
        "restore")
            restore_rules
            ;;
        "backup")
            backup_rules
            ;;
        "info")
            show_connection_info
            ;;
        "config")
            show_config
            ;;
        "cleanup")
            cleanup_rules
            ;;
        "help"|"--help"|"-h"|"")
            show_usage
            ;;
        *)
            log_error "未知命令: $1"
            echo ""
            show_usage
            exit 1
            ;;
    esac
}

# 脚本入口点
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
