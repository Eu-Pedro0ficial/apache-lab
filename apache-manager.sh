#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly INVENTORY_DIR="${SCRIPT_DIR}/inventory"
readonly INVENTORY_FILE="${INVENTORY_DIR}/hosts.yml"
readonly DIAGNOSE_PLAYBOOK="${SCRIPT_DIR}/playbooks/diagnose.yml"
readonly INSTALL_PLAYBOOK="${SCRIPT_DIR}/playbooks/install.yml"
readonly DEPLOY_PLAYBOOK="${SCRIPT_DIR}/playbooks/deploy-site.yml"
readonly VENV_BIN="${SCRIPT_DIR}/.venv/bin"

ANSIBLE_COMMAND=""
ANSIBLE_PLAYBOOK_COMMAND=""

declare -a HOST_ALIASES=()

pause() {
  printf '\nPressione Enter para continuar...'
  read -r _
}

require_dependencies() {
  local missing=()
  local command_name

  if [[ -x "${VENV_BIN}/ansible" && -x "${VENV_BIN}/ansible-playbook" ]]; then
    ANSIBLE_COMMAND="${VENV_BIN}/ansible"
    ANSIBLE_PLAYBOOK_COMMAND="${VENV_BIN}/ansible-playbook"
  else
    for command_name in ansible ansible-playbook; do
      command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
    done
    ANSIBLE_COMMAND="$(command -v ansible 2>/dev/null || true)"
    ANSIBLE_PLAYBOOK_COMMAND="$(command -v ansible-playbook 2>/dev/null || true)"
  fi

  if ((${#missing[@]} > 0)); then
    printf 'Erro: dependências ausentes: %s\n' "${missing[*]}" >&2
    printf 'Instale o Ansible antes de executar. Consulte o README.md.\n' >&2
    exit 1
  fi
}

ensure_inventory() {
  mkdir -p "$INVENTORY_DIR"
  if [[ ! -f "$INVENTORY_FILE" ]]; then
    printf '%s\n' '---' 'all:' '  children:' '    apache_lab:' '      hosts:' >"$INVENTORY_FILE"
    chmod 600 "$INVENTORY_FILE"
  fi
}

load_hosts() {
  mapfile -t HOST_ALIASES < <(
    awk '/^        [A-Za-z0-9_-]+:$/ { value=$1; sub(/:$/, "", value); print value }' "$INVENTORY_FILE"
  )
}

list_hosts() {
  load_hosts
  if ((${#HOST_ALIASES[@]} == 0)); then
    printf 'Nenhum servidor cadastrado.\n'
    return 1
  fi

  printf '\nServidores cadastrados:\n'
  local index
  for index in "${!HOST_ALIASES[@]}"; do
    printf '  %d - %s\n' "$((index + 1))" "${HOST_ALIASES[index]}"
  done
}

alias_exists() {
  local wanted="$1"
  local current
  load_hosts
  for current in "${HOST_ALIASES[@]}"; do
    [[ "$current" == "$wanted" ]] && return 0
  done
  return 1
}

yaml_escape() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/}
  value=${value//$'\r'/}
  printf '%s' "$value"
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-n}"
  local answer
  while true; do
    read -r -p "$prompt" answer
    answer="${answer:-$default}"
    case "${answer,,}" in
      s|sim) return 0 ;;
      n|nao|não) return 1 ;;
      *) printf 'Resposta inválida. Digite s ou n.\n' ;;
    esac
  done
}

register_host() {
  local alias address ssh_user ssh_port key_path become

  while true; do
    read -r -p 'Nome/alias do servidor: ' alias
    if [[ ! "$alias" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then
      printf 'Alias inválido. Use letras, números, "_" ou "-" e inicie com letra/número.\n'
    elif alias_exists "$alias"; then
      printf 'Já existe um servidor com o alias "%s".\n' "$alias"
    else
      break
    fi
  done

  while true; do
    read -r -p 'IP, hostname ou alias de ~/.ssh/config: ' address
    [[ -n "$address" && ! "$address" =~ [[:space:]] ]] && break
    printf 'Endereço inválido: informe um valor sem espaços.\n'
  done

  while true; do
    read -r -p 'Usuário SSH: ' ssh_user
    [[ "$ssh_user" =~ ^[A-Za-z_][A-Za-z0-9._-]*$ ]] && break
    printf 'Usuário SSH inválido.\n'
  done

  while true; do
    read -r -p 'Porta SSH [22]: ' ssh_port
    ssh_port="${ssh_port:-22}"
    if [[ "$ssh_port" =~ ^[0-9]+$ ]] && ((10#$ssh_port >= 1 && 10#$ssh_port <= 65535)); then
      ssh_port=$((10#$ssh_port))
      break
    fi
    printf 'Porta inválida. Informe um número entre 1 e 65535.\n'
  done

  read -r -p 'Caminho opcional da chave SSH [usar configuração SSH]: ' key_path
  if [[ -n "$key_path" ]]; then
    key_path="${key_path/#\~/$HOME}"
    if [[ ! -f "$key_path" ]]; then
      printf 'Aviso: a chave não existe neste momento: %s\n' "$key_path"
      if ! ask_yes_no 'Salvar o cadastro mesmo assim? [s/N] ' n; then
        printf 'Cadastro cancelado.\n'
        return
      fi
    fi
  fi

  if ask_yes_no 'O servidor necessita de sudo/become? [s/N] ' n; then
    become=true
  else
    become=false
  fi

  {
    printf '        %s:\n' "$alias"
    printf '          ansible_host: "%s"\n' "$(yaml_escape "$address")"
    printf '          ansible_user: "%s"\n' "$(yaml_escape "$ssh_user")"
    printf '          ansible_port: %d\n' "$ssh_port"
    printf '          ansible_become: %s\n' "$become"
    if [[ -n "$key_path" ]]; then
      printf '          ansible_ssh_private_key_file: "%s"\n' "$(yaml_escape "$key_path")"
    fi
  } >>"$INVENTORY_FILE"

  printf 'Servidor "%s" cadastrado com sucesso.\n' "$alias"
}

register_hosts_loop() {
  register_host
  while ask_yes_no 'Deseja adicionar mais um servidor? [s/N] ' n; do
    register_host
  done
}

select_hosts() {
  local selection token index
  local -a selected=()
  list_hosts || return 1
  printf 'Digite um ou mais números separados por vírgula, ou "todos".\n'
  read -r -p 'Seleção: ' selection
  selection="${selection//[[:space:]]/}"

  if [[ "${selection,,}" == "todos" ]]; then
    SELECTED_LIMIT=$(IFS=,; printf '%s' "${HOST_ALIASES[*]}")
    return 0
  fi

  IFS=',' read -r -a tokens <<<"$selection"
  for token in "${tokens[@]}"; do
    if [[ ! "$token" =~ ^[0-9]+$ ]]; then
      printf 'Seleção inválida: %s\n' "$token"
      return 1
    fi
    index=$((10#$token - 1))
    if ((index < 0 || index >= ${#HOST_ALIASES[@]})); then
      printf 'Servidor não encontrado: %s\n' "$token"
      return 1
    fi
    if [[ ! ",${selected[*]:-}," =~ ,${HOST_ALIASES[index]}, ]]; then
      selected+=("${HOST_ALIASES[index]}")
    fi
  done

  if ((${#selected[@]} == 0)); then
    printf 'Nenhum servidor selecionado.\n'
    return 1
  fi
  SELECTED_LIMIT=$(IFS=,; printf '%s' "${selected[*]}")
}

test_connectivity() {
  select_hosts || return
  printf '\nTestando conectividade com: %s\n\n' "$SELECTED_LIMIT"
  "$ANSIBLE_COMMAND" -i "$INVENTORY_FILE" all --limit "$SELECTED_LIMIT" -m ansible.builtin.ping || true
}

diagnose_apache() {
  select_hosts || return
  printf '\nExecutando diagnóstico somente de leitura em: %s\n\n' "$SELECTED_LIMIT"
  "$ANSIBLE_PLAYBOOK_COMMAND" -i "$INVENTORY_FILE" "$DIAGNOSE_PLAYBOOK" --limit "$SELECTED_LIMIT" || {
    printf '\nO diagnóstico terminou com falhas em um ou mais hosts. Confira o resumo acima.\n' >&2
  }
}

install_apache() {
  local ask_become=false
  local -a playbook_options=()

  select_hosts || return
  printf '\nServidores selecionados para instalação/verificação:\n'
  printf '  - %s\n' "${SELECTED_LIMIT//,/$'\n  - '}"
  printf '\nA instalação será bloqueada individualmente se houver conflito na porta 80.\n'
  if ! ask_yes_no 'Confirma a instalação do Apache2 nesses servidores? [s/N] ' n; then
    printf 'Instalação cancelada.\n'
    return
  fi

  if selected_hosts_require_become && ask_yes_no 'Solicitar senha de sudo/become ao executar? [s/N] ' n; then
    ask_become=true
  fi
  if [[ "$ask_become" == true ]]; then
    playbook_options+=(--ask-become-pass)
  fi

  printf '\nExecutando pré-verificações e instalação em: %s\n\n' "$SELECTED_LIMIT"
  "$ANSIBLE_PLAYBOOK_COMMAND" -i "$INVENTORY_FILE" "$INSTALL_PLAYBOOK" \
    --limit "$SELECTED_LIMIT" "${playbook_options[@]}" || {
    printf '\nA instalação terminou com falhas em um ou mais hosts. Confira os relatórios e o resumo acima.\n' >&2
  }
}

valid_domain() {
  local domain="$1"
  local label
  local -a labels=()
  [[ ${#domain} -le 253 && "$domain" == *.* && "$domain" != *..* ]] || return 1
  [[ "$domain" =~ ^[a-z0-9.-]+$ ]] || return 1
  IFS='.' read -r -a labels <<<"$domain"
  for label in "${labels[@]}"; do
    [[ -n "$label" && ${#label} -le 63 ]] || return 1
    [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
  done
}

valid_email() {
  local email="$1"
  local local_part domain_part
  [[ ${#email} -le 254 && "$email" =~ ^[A-Za-z0-9.!#$%\&\'*+/=?^_\`{|}~-]+@([A-Za-z0-9-]+\.)+[A-Za-z0-9-]+$ ]] || return 1
  local_part="${email%@*}"
  domain_part="${email##*@}"
  [[ ${#local_part} -le 64 ]] && valid_domain "${domain_part,,}"
}

valid_title() {
  local title="$1"
  [[ -n "$title" && ${#title} -le 120 && "$title" != *$'\n'* && "$title" != *$'\r'* && "$title" != *$'\t'* ]]
}

json_escape() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

selected_hosts_require_become() {
  local selected_alias
  local -a selected_aliases=()
  IFS=',' read -r -a selected_aliases <<<"$SELECTED_LIMIT"
  for selected_alias in "${selected_aliases[@]}"; do
    if awk -v wanted="$selected_alias" '
      $0 == "        " wanted ":" { in_host=1; next }
      /^        [A-Za-z0-9_-]+:$/ { in_host=0 }
      in_host && /^          ansible_become: true$/ { found=1 }
      END { exit !found }
    ' "$INVENTORY_FILE"; then
      return 0
    fi
  done
  return 1
}

deploy_site() {
  local site_domain site_alias admin_email site_title site_port
  local allow_existing=false allow_port_change=false ask_become=false extra_vars_file deploy_failed=false
  local -a playbook_options=()

  while true; do
    read -r -p 'Domínio principal: ' site_domain
    site_domain="${site_domain,,}"
    valid_domain "$site_domain" && break
    printf 'Domínio inválido. Use um FQDN como exemplo.lab, sem caminhos ou caracteres especiais.\n'
  done

  while true; do
    read -r -p 'Alias de domínio [opcional]: ' site_alias
    site_alias="${site_alias,,}"
    if [[ -z "$site_alias" ]]; then
      break
    elif [[ "$site_alias" == "$site_domain" ]]; then
      printf 'O alias deve ser diferente do domínio principal.\n'
    elif valid_domain "$site_alias"; then
      break
    else
      printf 'Alias de domínio inválido.\n'
    fi
  done

  while true; do
    read -r -p 'E-mail administrativo [opcional]: ' admin_email
    [[ -z "$admin_email" ]] && break
    valid_email "$admin_email" && break
    printf 'E-mail inválido.\n'
  done

  while true; do
    read -r -p 'Título da página demonstrativa: ' site_title
    valid_title "$site_title" && break
    printf 'Título inválido. Informe de 1 a 120 caracteres, sem controles.\n'
  done

  while true; do
    read -r -p 'Porta HTTP [80]: ' site_port
    site_port="${site_port:-80}"
    if [[ "$site_port" =~ ^[0-9]+$ ]] && ((10#$site_port >= 1 && 10#$site_port <= 65535)); then
      site_port=$((10#$site_port))
      break
    fi
    printf 'Porta inválida. Informe um número entre 1 e 65535.\n'
  done

  select_hosts || return

  printf '\nResumo da publicação:\n'
  printf '  Domínio: %s\n' "$site_domain"
  printf '  Alias: %s\n' "${site_alias:-não informado}"
  printf '  E-mail administrativo: %s\n' "${admin_email:-não informado}"
  printf '  Título: %s\n' "$site_title"
  printf '  Porta HTTP: %s\n' "$site_port"
  printf '  Servidores:\n  - %s\n' "${SELECTED_LIMIT//,/$'\n  - '}"
  printf '  DocumentRoot: /var/www/%s/public_html\n' "$site_domain"

  if ask_yes_no 'Se DOMINIO.conf já existir, autoriza atualizá-lo com backup e rollback? [s/N] ' n; then
    allow_existing=true
  fi
  if [[ "$allow_existing" == true ]] && \
    ask_yes_no "Se o domínio estiver publicado em outra porta, autoriza alterá-lo para ${site_port}? [s/N] " n; then
    allow_port_change=true
  fi
  if ! ask_yes_no 'Confirma a publicação com os dados acima? [s/N] ' n; then
    printf 'Publicação cancelada.\n'
    return
  fi

  if selected_hosts_require_become && ask_yes_no 'Solicitar senha de sudo/become ao executar? [s/N] ' n; then
    ask_become=true
    playbook_options+=(--ask-become-pass)
  fi

  extra_vars_file="$(mktemp "${TMPDIR:-/tmp}/apache-lab-site.XXXXXX.json")"
  chmod 600 "$extra_vars_file"
  printf '{"site_domain":"%s","site_alias":"%s","admin_email":"%s","site_title":"%s","site_port":%d,"allow_existing_vhost":%s,"allow_port_change":%s}\n' \
    "$(json_escape "$site_domain")" "$(json_escape "$site_alias")" \
    "$(json_escape "$admin_email")" "$(json_escape "$site_title")" "$site_port" \
    "$allow_existing" "$allow_port_change" >"$extra_vars_file"

  printf '\nPublicando %s em: %s\n\n' "$site_domain" "$SELECTED_LIMIT"
  if ! "$ANSIBLE_PLAYBOOK_COMMAND" -i "$INVENTORY_FILE" "$DEPLOY_PLAYBOOK" \
    --limit "$SELECTED_LIMIT" --extra-vars "@${extra_vars_file}" "${playbook_options[@]}"; then
    deploy_failed=true
  fi
  unlink "$extra_vars_file"

  if [[ "$deploy_failed" == true ]]; then
    printf '\nA publicação terminou com falhas em um ou mais hosts. Confira os relatórios e o resumo acima.\n' >&2
  fi
}

manage_servers() {
  local option
  while true; do
    printf '\nGerenciar servidores\n'
    printf '1 - Listar servidores\n2 - Adicionar servidor\n3 - Testar conectividade SSH/Ansible\n0 - Voltar\n'
    read -r -p 'Opção: ' option
    case "$option" in
      1) list_hosts || true; pause ;;
      2) register_hosts_loop; pause ;;
      3) test_connectivity; pause ;;
      0) return ;;
      *) printf 'Opção inválida.\n' ;;
    esac
  done
}

initial_host_setup() {
  load_hosts
  if ((${#HOST_ALIASES[@]} == 0)); then
    printf 'Não existem servidores cadastrados.\n'
    if ask_yes_no 'Deseja cadastrar o primeiro servidor? [S/n] ' s; then
      register_hosts_loop
    fi
  else
    list_hosts || true
    if ask_yes_no 'Deseja adicionar outro servidor? [s/N] ' n; then
      register_hosts_loop
    fi
  fi
}

main_menu() {
  local option
  while true; do
    printf '\nApache Lab Manager\n'
    printf '1 - Diagnosticar Apache\n2 - Instalar Apache\n3 - Publicar novo site\n4 - Gerenciar servidores\n0 - Sair\n'
    read -r -p 'Opção: ' option
    case "$option" in
      1) diagnose_apache; pause ;;
      2) install_apache; pause ;;
      3) deploy_site; pause ;;
      4) manage_servers ;;
      0) printf 'Até logo!\n'; return ;;
      *) printf 'Opção inválida.\n' ;;
    esac
  done
}

main() {
  export ANSIBLE_LOCAL_TEMP="${TMPDIR:-/tmp}/apache-lab-manager-${UID}"
  mkdir -p "$ANSIBLE_LOCAL_TEMP"
  chmod 700 "$ANSIBLE_LOCAL_TEMP"
  require_dependencies
  ensure_inventory
  initial_host_setup
  main_menu
}

main "$@"

