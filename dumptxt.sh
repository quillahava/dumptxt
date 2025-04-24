#!/usr/bin/env bash

# Config file path (can override with -c)
CONFIG_FILE="${CONFIG_FILE:-$HOME/.config/dumptxt/config.toml}"

# CLI defaults
include_binary=false
preserve_encoded=false
exclude_patterns=()
il_override=()
wl_override=()
max_size=0
ext_filters=()
summary_only=false
output_file=""
max_depth=-1

print_usage() {
  echo "Использование: $0 [опции] [директория]"
  echo "Если директория не указана, используется текущая директория."
  echo
  echo "Опции:" 
  echo "  -o <file>        Указать имя выходного файла (по умолчанию: <директория>_output.txt)"
  echo "  -x               Включить бинарные файлы"
  echo "  -r               Сохранять оригинальные закодированные данные"
  echo "  -E <p1,p2>       Исключить по шаблонам"
  echo "  -i <section>     Секция ignore_list из config"
  echo "  -w <section>     Секция white_list из config"
  echo "  -m <KB>          Пропустить файлы больше указанного размера"
  echo "  -f <ext1,ext2>   Обрабатывать только файлы с указанными расширениями"
  echo "  -s               Только дерево директорий"
  echo "  -d <depth>       Максимальная глубина рекурсии (по умолчанию: без ограничений)"
  echo "  -c <file>        Использовать кастомный файл config.toml"
  echo "  -h, --help       Показать это сообщение"
  exit 1
}

# Parse toml lists
toml_list() {
  local section=$1
  grep -A1 "\[${section}\]" "$CONFIG_FILE" 2>/dev/null \
    | sed -n 's/paths *= *\[\(.*\)\]/\1/p' \
    | tr -d '" ' | tr ',' ' '
}

# Load config defaults
if [[ -f "$CONFIG_FILE" ]]; then
  default_ignores=( $(toml_list ignore_list) )
  default_whitelist=( $(toml_list white_list) )
else
  default_ignores=("__pycache__" ".git" "node_modules" ".next" "dist")
  default_whitelist=()
fi

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) output_file="$2"; shift 2;;
    -x) include_binary=true; shift;;
    -r) preserve_encoded=true; shift;;
    -E) IFS=',' read -r -a exclude_patterns <<< "$2"; shift 2;;
    --exclude=*) IFS=',' read -r -a exclude_patterns <<< "${1#*=}"; shift;;
    -i) il_override=("$2"); shift 2;;
    --il=*) il_override=("${1#*=}"); shift;;
    -w) wl_override=("$2"); shift 2;;
    --wl=*) wl_override=("${1#*=}"); shift;;
    -m) max_size=$2; shift 2;;
    --max-size=*) max_size=${1#*=}; shift;;
    -f) IFS=',' read -r -a ext_filters <<< "$2"; shift 2;;
    --ext=*) IFS=',' read -r -a ext_filters <<< "${1#*=}"; shift;;
    -s|--summary) summary_only=true; shift;;
    -d) max_depth="$2"; shift 2;;
    --max-depth=*) max_depth="${1#*=}"; shift;;
    -c) CONFIG_FILE="$2"; shift 2;;
    --config=*) CONFIG_FILE="${1#*=}"; shift;;
    -h|--help) print_usage;;
    --) shift; break;;
    -*|--*) echo "Неизвестная опция $1"; print_usage;;
    *) break;;
  esac
done

# Directory handling
if [[ $# -eq 0 ]]; then
  input_dir="$(pwd)"
  dir_name="$(basename "$(pwd)")"
elif [[ $# -eq 1 ]]; then
  input_dir="$1"
  dir_name="$(basename "$1")"
else
  echo "Ошибка: ожидается не более одного аргумента директории"
  print_usage
fi

# Set default output file if not specified
if [[ -z "$output_file" ]]; then
  output_file="${dir_name}_output.txt"
fi

# Validate
[[ ! -d "$input_dir" ]] && echo "Ошибка: $input_dir не директория" && exit 1

# Validate max_depth
if [[ "$max_depth" != "-1" ]]; then
  if ! [[ "$max_depth" =~ ^[0-9]+$ ]] || [[ "$max_depth" -lt 0 ]]; then
    echo "Ошибка: -d должен быть неотрицательным целым числом"
    exit 1
  fi
fi

# Prepare ignore/whitelist lists
[[ ${#il_override[@]} -gt 0 ]] && ignores=("${il_override[@]}") || ignores=("${default_ignores[@]}")
[[ ${#wl_override[@]} -gt 0 ]] && whitelist=("${wl_override[@]}") || whitelist=("${default_whitelist[@]}")

# Add output file to ignores to prevent it from being processed
ignores+=("${output_file}")

# Reset output
> "$output_file"
echo "Обработка: $input_dir" >&2

# Build find filters
find_args=()
[[ "$max_depth" != "-1" ]] && find_args+=(-maxdepth "$max_depth")
for pat in "${ignores[@]}" "${exclude_patterns[@]}" "tree_list.tmp"; do
  find_args+=( -path "*/$pat" -prune -o )
done
if [[ ${#whitelist[@]} -gt 0 ]]; then
  find_args+=("(")
  for pat in "${whitelist[@]}"; do
    find_args+=( -path "*/$pat" -o )
  done
  find_args+=(")" -print)
else
  find_args+=( -type f -print )
fi

# Process file
process_file() {
  local file="$1"
  (( max_size>0 )) && {
    size_kb=$(( $(stat -c%s "$file")/1024 ))
    (( size_kb>max_size )) && { echo "Пропущен(size): $file" >> "$output_file"; return; }
  }
  [[ ${#ext_filters[@]} -gt 0 ]] && {
    ext="${file##*.}"
    [[ ! " ${ext_filters[*]} " =~ " $ext " ]] && { echo "Пропущен(ext): $file" >> "$output_file"; return; }
  }
  mime=$(file --mime-type -b "$file")
  [[ "$include_binary" == false && ! "$mime" =~ text/ ]] && { echo "Пропущен(bin): $file" >> "$output_file"; return; }
  echo -e "\n===== $file =====" >> "$output_file"
  if file "$file" | grep -q troff; then
    man -P cat "$file" >> "$output_file" 2>/dev/null || \
      echo "[Не удалось прочесть man: $file]" >> "$output_file"
  else
    if [[ "$preserve_encoded" == false && "$summary_only" == false ]]; then
      sed -E -e 's/([A-Za-z0-9+\/]{50,}=*)/<[base64]>/' \
             -e 's/(\[?([-+]?[0-9]+,?\s*){20,}\]?)/<[numeric array]>/' \
             -e 's/([A-Za-z0-9]{100,})/<[obf]>/' \
             -e 's/("[A-Za-z0-9+\/=]{100,}")/<[long str]>/' \
        "$file" >> "$output_file" 2>/dev/null || \
        echo "[Ошибка чтения: $file]" >> "$output_file"
    elif [[ "$summary_only" == false ]]; then
      cat "$file" >> "$output_file" 2>/dev/null || \
        echo "[Ошибка чтения: $file]" >> "$output_file"
    fi
  fi
}

# Build tree + content
echo -e "===== Структура $dir_name =====\n" >> "$output_file"
cd "$input_dir" || { echo "Ошибка: не удалось перейти в директорию $input_dir"; exit 1; }
tmp_file="/tmp/dumptxt_tree_list_$$.tmp"
find . "${find_args[@]}" | sed 's|^\./||' > "$tmp_file"
while IFS= read -r entry; do
  [[ -n "$entry" ]] || continue
  echo "$entry" >> "$output_file"
  [[ "$summary_only" == false ]] && process_file "$entry"
done < "$tmp_file"
rm "$tmp_file"

echo "Готово: $output_file" >&2
