#!/usr/bin/env bash

# Directory name of this file
readonly THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
readonly TEST_TMP="${THIS_DIR}/test_tmp"
readonly OLD_PATH="${PATH}"
IFS=" " read -r TTY_ROWS TTY_COLS < <(stty size)
TTY_ROWS=${TTY_ROWS:-40}
TTY_COLS=${TTY_COLS:-80}
readonly TTY_ROWS TTY_COLS

tmux_version_number() {
  local _tmux_version=""
  if ! ${TMUX_EXEC} -V &> /dev/null; then
    # From tmux 0.9 to 1.3, there is no -V option.
    # Adjust all to 0.9
    _tmux_version="tmux 0.9"
  else
    _tmux_version="$(${TMUX_EXEC} -V)"
  fi
  echo "${_tmux_version}" | perl -anle 'printf $F[1]'
}

# Check whether the given version is less than current tmux version.
# In case of tmux version is 1.7, the result will be like this.
##  arg  -> result
#   1.5  -> 1
#   1.6  -> 1
#   1.7  -> 1
#   1.8  -> 0
#   1.9  -> 0
#   1.9a -> 0
#   2.0  -> 0
is_less_than() {
  # Simple numerical comparison does not work because there is the version like "1.9a".
  if [[ "$( (tmux_version_number; echo; echo "$1") | sort -n | head -n 1)" != "$1" ]];then
    return 0
  else
    return 1
  fi
}

## Input:
##         d51b,120x41,0,0[120x13,0,0{60x13,0,0,1,59x13,61,0,6},120x13,0,14{60x13,0,14,4,59x13,61,14,5},120x13,0,28{60x13,0,28,2,59x13,61,28,3}]
## Output:
##         60 13 59 13
##         60 13 59 13
##         60 13 59 13
##
## Input:
##         f0c8,204x48,0,0[204x24,0,0,0,204x11,0,25{102x11,0,25,2,101x11,103,25,4},204x11,0,37,3]
## Output:
##         204 24
##         102 11 101 11
##         204 11
## Output format is
##         <Width of pane 1 row 1 column> <Height of 1 row 1 column> <Width of 1 row 2 column> <Height of 1 row 2 column> ...
##         <Width of pane 2 row 1 column> <Height of 2 row 1 column> <Width of 2 row 2 column> <Height of 2 row 2 column> ...
window_layout_parse() {
  sed 's/{/,&/g' \
    | grep -o -E '[0-9]+x[0-9]+,[0-9]+,[0-9]+,([0-9]+|\{[^}]+\})' \
    | sed 's/{//;s/}//' \
    | awk -F, '{printf("%s ", $1); for(i=4;i<=NF;i=i+4){printf "%s ", $i};print ""}' \
    | tr x ' ' \
    | awk 'NF>3{for(i=3;i<=NF;i++){printf("%s"OFS, $i);};print ""} NF<=3{print $1,$2}'
}

WINDOW_LAYOUT_PAYLOAD=
window_layout_set() {
  local _payload="$1"
  WINDOW_LAYOUT_PAYLOAD="$(echo "${_payload}" | window_layout_parse)"
  return 0
}

window_layout_get() {
  local _op="$1" ## "height" "width" or "cols"
  local _row="${2-}"
  local _col="${3-}"

  if [[ "$_op" == "width" ]] || [[ "$_op" == "height" ]]; then
    (( _col = _col * 2 ))
    [[ "$_op" == "width" ]] && (( _col = _col - 1 ))
    printf "%s\\n" "${WINDOW_LAYOUT_PAYLOAD}" | awk "NR==$_row{print \$($_col)}"
  elif [[ "$_op" == "cols" ]]; then
    printf "%s\\n" "${WINDOW_LAYOUT_PAYLOAD}" | awk '{print NF/2}' | xargs
  fi
  return 0
}

window_layout_dump() {
  if ! type column > /dev/null 2>&1 ;then
    printf "%s\\n" "${WINDOW_LAYOUT_PAYLOAD}"
  else
    printf "%s\\n" "${WINDOW_LAYOUT_PAYLOAD}" \
      | sed -r 's/([0-9]+) ([0-9]+)/| w:\1 h:\2/g' \
      | sed 's/^/@/' \
      | sed 's/$/@|/' \
      | awk 'BEGIN {s="@|---@|"; print s} {print}' \
      | column -t -s '@' \
      | sed '/---/s/ /-/g' \
      | awk 'NR==1{s=$0;print $0} NR > 1{print $0; print s}' \
      | sed 's/|-/+-/g;s/-|/-+/g' \
      | cat
  fi
}

# !!Run this function at first!!
check_version() {
  local _exec="${BIN_DIR}${EXEC}"
  ${_exec} --dry-run A
  # If tmux version is less than 1.8, skip rest of the tests.
  if is_less_than "1.8" ;then
    echo "Skip rest of the tests." >&2
    echo "Because this version is out of support." >&2
    exit 0
  fi
}

create_tmux_session() {
  local _socket_file="$1"
  ${TMUX_EXEC} -S "${_socket_file}" new-session -d
  # Once attach tmux session and detach it.
  # Because, pipe-pane feature does not work with tmux 1.8 (it might be bug).
  # To run pipe-pane, it is necessary to attach the session.
  ${TMUX_EXEC} -S "${_socket_file}" send-keys "sleep 1 && ${TMUX_EXEC} detach-client" C-m
  ${TMUX_EXEC} -S "${_socket_file}" attach-session
}

is_allow_rename_value_on() {
  local _socket_file="${THIS_DIR}/.xpanes-shunit"
  local _value_allow_rename
  local _value_automatic_rename
  create_tmux_session "${_socket_file}"
  _value_allow_rename="$(${TMUX_EXEC} -S "${_socket_file}" show-window-options -g | awk '$1=="allow-rename"{print $2}')"
  _value_automatic_rename="$(${TMUX_EXEC} -S "${_socket_file}" show-window-options -g | awk '$1=="automatic-rename"{print $2}')"
  close_tmux_session "${_socket_file}"
  if [ "${_value_allow_rename}" = "on" ] ;then
    return 0
  fi
  if [ "${_value_automatic_rename}" = "on" ] ;then
    return 0
  fi
  return 1
}

exec_tmux_session() {
  local _socket_file="$1" ;shift
  # local _tmpdir=${SHUNIT_TMPDIR:-/tmp}
  # echo "send-keys: cd ${BIN_DIR} && $* && touch ${SHUNIT_TMPDIR}/done" >&2
  # Same reason as the comments near "create_tmux_session".
  ${TMUX_EXEC} -S "${_socket_file}" send-keys "cd ${BIN_DIR} && $* && touch ${SHUNIT_TMPDIR}/done && sleep 1 && ${TMUX_EXEC} detach-client" C-m
  ${TMUX_EXEC} -S "${_socket_file}" attach-session
  # Wait until tmux session is completely established.
  for i in $(seq 30) ;do
    # echo "exec_tmux_session: wait ${i} sec..."
    sleep 1
    if [ -e "${SHUNIT_TMPDIR}/done" ]; then
      rm -f "${SHUNIT_TMPDIR}/done"
      break
    fi
    # Tmux session does not work.
    if [ "${i}" -eq 30 ]; then
      echo "Tmux session timeout" >&2
      return 1
    fi
  done
}

capture_tmux_session() {
  local _socket_file="$1"
  ${TMUX_EXEC} -S "${_socket_file}" capture-pane
  ${TMUX_EXEC} -S "${_socket_file}" show-buffer
}

close_tmux_session() {
  local _socket_file="$1"
  ${TMUX_EXEC} -S "${_socket_file}" kill-session
  rm -f "${_socket_file}"
}

get_window_id_from_prefix() {
  local _socket_file="$1" ; shift
  local _window_name_prefix="$1" ; shift
  local _window_id=
  ## tmux bug: tmux does not handle the window_name which has dot(.) at the begining of the name. Use window_id instead.
  _window_id=$(${TMUX_EXEC} -S "${_socket_file}" list-windows -F '#{window_name} #{window_id}' \
    | grep "^${_window_name_prefix}" \
    | head -n 1 \
    | perl -anle 'print $F[$#F]')
      echo "${_window_id}"
    }

wait_panes_separation() {
  local _socket_file="$1"
  local _window_name_prefix="$2"
  local _expected_pane_num="$3"
  local _window_id=""
  local _pane_num=""
  local _wait_seconds=30
  # Wait until pane separation is completed
  for i in $(seq "${_wait_seconds}") ;do
    sleep 1
    _window_id=$(get_window_id_from_prefix "${_socket_file}" "${_window_name_prefix}")
    printf "%s\\n" "wait_panes_separation: ${i} sec..." >&2
    ${TMUX_EXEC} -S "${_socket_file}" list-windows -F '#{window_name} #{window_id}' >&2
    printf "_window_id:[%s]\\n" "${_window_id}"
    if [ -n "${_window_id}" ]; then
      # ${TMUX_EXEC} -S "${_socket_file}" list-panes -t "${_window_id}"
      _pane_num="$(${TMUX_EXEC} -S "${_socket_file}" list-panes -t "${_window_id}" | grep -c .)"
      # tmux -S "${_socket_file}" list-panes -t "${_window_name}"
      if [ "${_pane_num}" = "${_expected_pane_num}" ]; then
        ${TMUX_EXEC} -S "${_socket_file}" list-panes -t "${_window_id}" >&2
        # Wait several seconds to ensure the completion.
        # Even the number of panes equals to expected number,
        # the separation is not complated sometimes.
        sleep 3
        break
      fi
    fi
    # Still not separated.
    if [ "${i}" -eq "${_wait_seconds}" ]; then
      fail "wait_panes_separation: Too long time for window separation. Aborted." >&2
      return 1
    fi
  done
  return 0
}

wait_all_files_creation(){
  local _wait_seconds=30
  local _break=1
  # Wait until specific files are created.
  for i in $(seq "${_wait_seconds}") ;do
    sleep 1
    _break=1
    for f in "$@" ;do
      if ! [ -e "${f}" ]; then
        # echo "${f}:does not exist." >&2
        _break=0
      fi
    done
    if [ "${_break}" -eq 1 ]; then
      break
    fi
    if [ "${i}" -eq "${_wait_seconds}" ]; then
      echo "wait_all_files_creation: Test failed" >&2
      return 1
    fi
  done
  return 0
}

wait_existing_file_number(){
  local _target_dir="$1"
  local _expected_num="$2"
  local _num_of_files=0
  local _wait_seconds=30
  # Wait until specific number of files are created.
  for i in $(seq "${_wait_seconds}") ;do
    sleep 1
    _num_of_files=$(printf "%s\\n" "${_target_dir}"/* | grep -c .)
    if [ "${_num_of_files}" = "${_expected_num}" ]; then
      break
    fi
    if [ "${i}" -eq "${_wait_seconds}" ]; then
      echo "wait_existing_file_number: Test failed" >&2
      return 1
    fi
  done
  return 0
}

all_non_empty_files(){
  local _count=0
  for f in "$@";do
    # if the file is non empty
    if [ -s "$f" ]; then
      _count=$(( _count + 1 ))
    else
      echo "${FUNCNAME[0]}: $f is still empty" >&2
    fi
  done
  if [[ $_count -eq $# ]]; then
    # echo "all_non_empty_files:non empty: $*" >&2
    return 0
  fi
  return 1
}

wait_all_non_empty_files(){
  local _num_of_files=0
  local _wait_seconds=5
  # Wait until specific number of files are created.
  for i in $(seq "${_wait_seconds}") ;do
    if all_non_empty_files "$@"; then
      break
    fi
    if [ "${i}" -eq "${_wait_seconds}" ]; then
      echo "${FUNCNAME[0]}: Test failed" >&2
      return 1
    fi
    sleep 1
  done
  return 0
}

between_plus_minus() {
  local _range="$1"
  shift
  echo "$(( ( $1 + _range ) >= $2 && $2 >= ( $1 - _range ) ))"
}

# Returns the index of the window and number of it's panes.
# The reason why it does not use #{window_panes} is, tmux 1.6 does not support the format.
get_window_having_panes() {
  local _socket_file="$1"
  local _pane_num="$2"
  while read -r idx;
  do
    echo -n "${idx} "; ${TMUX_EXEC} -S "${_socket_file}" list-panes -t "${idx}" -F '#{pane_index}' | grep -c .
  done < <(${TMUX_EXEC}  -S "${_socket_file}" list-windows -F '#{window_index}') \
    | awk '$2==pane_num{print $1}' pane_num="${_pane_num}" | head -n 1
}

assert_cols() {
  local _socket_file="$1" ; shift
  local _window_name_prefix="$1" ; shift
  _window_id="$(get_window_id_from_prefix "$_socket_file" "$_window_name_prefix" )"
  window_layout_set "$( ${TMUX_EXEC} -S "${_socket_file}" list-pane -t "${_window_id}" -F '#{window_layout}' | head -n 1 )"
  echo "== Window Layout Dump (window_id:[$_window_id]) =="
  window_layout_dump
  IFS=" " assertEquals "$*" "$(window_layout_get cols)"
}

assert_same_width_same_cols() {
  local _socket_file="$1" ; shift
  local _window_name_prefix="$1" ; shift
  local _start_row="$1" ; shift
  local _start_col="$1" ; shift
  local _end_row="$1" ; shift
  local _end_col="$1" ; shift
  local _window_id=
  _window_id="$(get_window_id_from_prefix "$_socket_file" "$_window_name_prefix" )"
  window_layout_set "$( ${TMUX_EXEC} -S "${_socket_file}" list-pane -t "${_window_id}" -F '#{window_layout}' | head -n 1 )"

  local col="$_start_col"
  for (( ; col <= _end_col; col++ )); do
    local row="$_start_row"
    local _base_width=
    _base_width=$(window_layout_get width "$row" "$col")
    for (( ; row <= _end_row; row++ )); do
      local _target_width=
      _target_width=$(window_layout_get width "$row" "$col")
      assertEquals 1 "$(( _base_width == _target_width ))" || \
      echo "${FUNCNAME[0]} [row=1 col=$col width=${_base_width}] vs [row=$row col=$col width=${_target_width}]"
    done
  done
}

assert_same_height_same_rows() {
  local _socket_file="$1" ; shift
  local _window_name_prefix="$1" ; shift
  local _start_row="$1" ; shift
  local _start_col="$1" ; shift
  local _end_row="$1" ; shift
  local _end_col="$1" ; shift
  local _window_id=
  _window_id="$(get_window_id_from_prefix "$_socket_file" "$_window_name_prefix" )"
  window_layout_set "$( ${TMUX_EXEC} -S "${_socket_file}" list-pane -t "${_window_id}" -F '#{window_layout}' | head -n 1 )"

  local row="$_start_row"
  for (( ; row <= _end_row; row++ )); do
    local col="$_start_col"
    local _base_height=
    _base_height=$(window_layout_get height "$row" "$col")
    for (( ; col <= _end_col; col++ )); do
      local _target_height=
      _target_height=$(window_layout_get height "$row" "$col")
      assertEquals 1 "$(( _base_height == _target_height ))" || \
      echo "${FUNCNAME[0]} [row=1 col=$col height=${_base_height}] vs [row=$row col=$col height=${_target_height}]"
    done
  done
}

assert_near_width_each_cols() {
  local _socket_file="$1" ; shift
  local _window_name_prefix="$1" ; shift
  local _start_row="$1" ; shift
  local _start_col="$1" ; shift
  local _end_row="$1" ; shift
  local _end_col="$1" ; shift
  local _window_id=
  _window_id="$(get_window_id_from_prefix "$_socket_file" "$_window_name_prefix" )"
  window_layout_set "$( ${TMUX_EXEC} -S "${_socket_file}" list-pane -t "${_window_id}" -F '#{window_layout}' | head -n 1 )"

  local row="$_start_row"
  for (( ; row <= _end_row; row++ )); do
    local col="$_start_col"
    local _base_width=
    _base_width=$(window_layout_get width "$row" "$col")
    for (( ; col <= _end_col; col++ )); do
      local _target_width=
      _target_width=$(window_layout_get width "$row" "$col")
      assertEquals 1 "$(between_plus_minus 1 "${_base_width}" "${_target_width}")" || \
      echo "${FUNCNAME[0]} [row=1 col=$col width=${_base_width}] vs [row=$row col=$col width=${_target_width}]"
    done
  done
}

assert_near_height_each_rows() {
  local _socket_file="$1" ; shift
  local _window_name_prefix="$1" ; shift
  local _start_row="$1" ; shift
  local _start_col="$1" ; shift
  local _end_row="$1" ; shift
  local _end_col="$1" ; shift
  local _window_id=
  _window_id="$(get_window_id_from_prefix "$_socket_file" "$_window_name_prefix" )"
  window_layout_set "$( ${TMUX_EXEC} -S "${_socket_file}" list-pane -t "${_window_id}" -F '#{window_layout}' | head -n 1 )"

  local col="$_start_col"
  for (( ; col <= _end_col; col++ )); do
    local row="$_start_row"
    local _base_height=
    _base_height=$(window_layout_get height "$row" "$col")
    for (( ; row <= _end_row; row++ )); do
      local _target_height=
      _target_height=$(window_layout_get height "$row" "$col")
      assertEquals 1 "$(between_plus_minus 1 "${_base_height}" "${_target_height}")" || \
      echo "${FUNCNAME[0]} [row=1 col=$col height=${_base_height}] vs [row=$row col=$col height=${_target_height}]"
    done
  done
}

assert_horizontal_two_panes() {
  local _socket_file="$1"
  local _window_name="$2"
  # Window should be divided like this.
  # +---+---+
  # | A | B |
  # +---+---+
  assert_cols "$_socket_file" "$_window_name" 2
  assert_same_height_same_rows "$_socket_file" "$_window_name" 1 1 1 2
  assert_near_width_each_cols "$_socket_file" "$_window_name" 1 1 1 2
}

assert_tiled_three_panes() {
  local _socket_file="$1"
  local _window_name="$2"
  # Window should be divided like this.
  # +---+---+
  # | A | B |
  # +---+---+
  # |   C   |
  # +---+---+
  assert_cols "$_socket_file" "$_window_name" 2 1
  assert_near_width_each_cols "$_socket_file" "$_window_name" 1 1 1 2
  assert_near_height_each_rows "$_socket_file" "$_window_name" 1 1 2 1
}

assert_tiled_four_panes() {
  local _socket_file="$1"
  local _window_name="$2"
  # Window should be divided like this.
  # +---+---+
  # | A | B |
  # +---+---+
  # | C | D |
  # +---+---+
  assert_cols "$_socket_file" "$_window_name" 2 2
  assert_same_width_same_cols "$_socket_file" "$_window_name" 1 1 2 2
  assert_same_height_same_rows "$_socket_file" "$_window_name" 1 1 2 2
  assert_near_width_each_cols "$_socket_file" "$_window_name" 1 1 2 2
  assert_near_height_each_rows "$_socket_file" "$_window_name" 1 1 2 2
}

assert_tiled_five_panes() {
  local _socket_file="$1"
  local _window_name="$2"
  # Window should be divided like this.
  # +---+---+
  # | A | B |
  # +---+---+
  # | C | D |
  # +---+---+
  # |   E   |
  # +---+---+
  assert_cols "$_socket_file" "$_window_name" 2 2 1
  assert_same_width_same_cols "$_socket_file" "$_window_name" 1 1 2 2
  assert_same_height_same_rows "$_socket_file" "$_window_name" 1 1 2 2
  assert_near_width_each_cols "$_socket_file" "$_window_name" 1 1 2 2
  assert_near_height_each_rows "$_socket_file" "$_window_name" 1 1 3 1
}

assert_vertical_two_panes() {
  local _socket_file="$1"
  local _window_name="$2"
  # Window should be divided like this.
  # +-------+
  # |   A   |
  # +-------+
  # |   B   |
  # +-------+
  assert_cols "$_socket_file" "$_window_name" 1 1
  assert_same_width_same_cols "$_socket_file" "$_window_name" 1 1 2 1
  assert_near_height_each_rows "$_socket_file" "$_window_name" 1 1 2 1
}

assert_vertical_three_panes() {
  local _socket_file="$1"
  local _window_name="$2"
  # Window should be divided like this.
  # +-------+
  # |   A   |
  # +-------+
  # |   B   |
  # +-------+
  # |   C   |
  # +-------+
  assert_cols "$_socket_file" "$_window_name" 1 1 1
  assert_same_width_same_cols "$_socket_file" "$_window_name" 1 1 3 1
  assert_near_height_each_rows "$_socket_file" "$_window_name" 1 1 3 1
}

assert_horizontal_three_panes() {
  local _socket_file="$1"
  local _window_name="$2"
  # Window should be divided like this.
  # +---+---+---+
  # | A | B | C |
  # +---+---+---+
  assert_cols "$_socket_file" "$_window_name" 3
  assert_same_height_same_rows "$_socket_file" "$_window_name" 1 1 1 3
  assert_near_width_each_cols "$_socket_file" "$_window_name" 1 1 1 3
}

set_tmux_exec_randomly () {
  local _num
  local _exec
  _num=$((RANDOM % 4));
  _exec="$(command -v tmux)"

  if [[ ${_num} -eq 0 ]];then
    export TMUX_XPANES_EXEC="${_exec} -2"
  elif [[ ${_num} -eq 1 ]];then
    export TMUX_XPANES_EXEC="${_exec}"
  elif [[ ${_num} -eq 2 ]];then
    unset TMUX_XPANES_EXEC
  elif [[ ${_num} -eq 3 ]];then
    export TMUX_XPANES_EXEC="tmux -2"
  fi
}

change_terminal_size() {
  if ! type stty &> /dev/null ;then
    return 1
  fi
  stty rows 40 cols 80
}

restore_terminal_size() {
  stty rows "${TTY_ROWS}" cols "${TTY_COLS}"
  type resize &> /dev/null && resize
}

setUp(){
  export XDG_CACHE_HOME="${SHUNIT_TMPDIR}/cache"
  cd "${BIN_DIR}" || exit
  mkdir -p "${TEST_TMP}"
  set_tmux_exec_randomly
  echo ">>>>>>>>>>" >&2
  echo "TMUX_XPANES_EXEC ... '${TMUX_XPANES_EXEC}'" >&2
}

tearDown(){
  rm -rf "${TEST_TMP}"
  echo "<<<<<<<<<<" >&2
  echo >&2
}

oneTimeTearDown() {
  echo "in oneTimeTearDown"
}


###:-:-:INSERT_TESTING:-:-:###

readonly TMUX_EXEC=$(command -v tmux)
if [ -n "$BASH_VERSION" ]; then
  # This is bash
  echo "Testing for bash $BASH_VERSION"
  echo "tmux path: ${TMUX_EXEC}"
  echo "            $(${TMUX_EXEC} -V)"
  echo
fi

if [ -n "$TMUX" ]; then
 echo "[Error] Do NOT execute this test inside of TMUX session." >&2
 exit 1
fi

if [ -n "$TMUX_XPANES_LOG_FORMAT" ]; then
 echo "[Warning] TMUX_XPANES_LOG_FORMAT is defined." >&2
 echo "During the test, this variable is updated." >&2
 echo "    Executed: export TMUX_XPANES_LOG_FORMAT=" >&2
 echo "" >&2
 export TMUX_XPANES_LOG_FORMAT=
fi

if [ -n "$TMUX_XPANES_LOG_DIRECTORY" ]; then
 echo "[Warning] TMUX_XPANES_LOG_DIRECTORY is defined." >&2
 echo "During the test, this variable is updated." >&2
 echo "    Executed: export TMUX_XPANES_LOG_DIRECTORY=" >&2
 echo "" >&2
 export TMUX_XPANES_LOG_DIRECTORY=
fi


if is_allow_rename_value_on; then
  echo "[Error] tmux's 'allow-rename' or 'automatic-rename' window option is now 'on'." >&2
  echo "Please make it off before starting testing." >&2
  echo "Execute this:
    echo 'set-window-option -g allow-rename off' >> ~/.tmux.conf
    echo 'set-window-option -g automatic-rename off' >> ~/.tmux.conf" >&2
  exit 1
fi

BIN_DIR="${THIS_DIR}/../bin/"
# Get repository name which equals to bin name.
# BIN_NAME="$(basename $(git rev-parse --show-toplevel))"
BIN_NAME="xpanes"
EXEC="./${BIN_NAME}"
check_version

# Test start
# shellcheck source=/dev/null
. "${THIS_DIR}/shunit2/shunit2"
