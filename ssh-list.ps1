Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 接続先リスト（CSVから読み込み）
$csvPath = Join-Path $PSScriptRoot "../data/machine_list.csv"
if (Test-Path $csvPath) {
    $sshTargets = Import-Csv -Path $csvPath -Encoding utf8
} else {
    Write-Error "CSV file not found: $csvPath"
    exit 1
}


# フォームの基本設定
$form = New-Object Windows.Forms.Form
$form.Text = "SSH Quick Connect"
$form.Size = New-Object Drawing.Size(800, 600)
$form.StartPosition = "CenterScreen"
$form.TopMost = $true

# フォントの設定（ここで大きさを調整）
$fontSize = 18
$font = New-Object Drawing.Font("Meiryo UI", $fontSize)

# DataGridViewの設定 (Out-GridView風)
$dataGridView = New-Object Windows.Forms.DataGridView
$dataGridView.Dock = "Fill"
$dataGridView.Font = $font
$dataGridView.AllowUserToAddRows = $false      # 空白行の追加を禁止
$dataGridView.AllowUserToDeleteRows = $false   # 行の削除を禁止
$dataGridView.ReadOnly = $true                 # 編集不可にする
$dataGridView.SelectionMode = [Windows.Forms.DataGridViewSelectionMode]::FullRowSelect # 行全体を選択
$dataGridView.RowHeadersVisible = $false       # 左端の余白（行ヘッダー）を隠す
$dataGridView.BackgroundColor = [Drawing.Color]::White # 背景色を白に
# 列ヘッダーのハイライトを無効化し、常に標準の灰色に保つ
$dataGridView.EnableHeadersVisualStyles = $false
$dataGridView.ColumnHeadersDefaultCellStyle.BackColor = [Drawing.SystemColors]::Control
$dataGridView.ColumnHeadersDefaultCellStyle.SelectionBackColor = [Drawing.SystemColors]::Control
$dataGridView.ColumnHeadersDefaultCellStyle.ForeColor = [Drawing.Color]::Black
$dataGridView.ColumnHeadersDefaultCellStyle.SelectionForeColor = [Drawing.Color]::Black
# 行の高さを文字サイズに合わせて自動調整する
$dataGridView.AutoSizeRowsMode = [Windows.Forms.DataGridViewAutoSizeRowsMode]::AllCells
# 列ヘッダー（一番上のName, Hostなどの行）の高さを自動調整する
$dataGridView.ColumnHeadersHeightSizeMode = [Windows.Forms.DataGridViewColumnHeadersHeightSizeMode]::AutoSize
# カラム幅の自動調整
$dataGridView.AutoSizeColumnsMode = [Windows.Forms.DataGridViewAutoSizeColumnsMode]::AllCells


# カラムの追加 (名前, ホスト, ユーザー)
$dataGridView.Columns.Add("Name", "Name") | Out-Null
$dataGridView.Columns.Add("Host", "Host") | Out-Null
$dataGridView.Columns.Add("User", "User") | Out-Null

# 文字色を青色、選択時の背景色を水色に設定
$dataGridView.DefaultCellStyle.ForeColor = [Drawing.Color]::Blue
$dataGridView.DefaultCellStyle.SelectionBackColor = [Drawing.Color]::LightBlue
$dataGridView.DefaultCellStyle.SelectionForeColor = [Drawing.Color]::Blue

# データの流し込み
foreach ($target in $sshTargets) {
    # データを追加し、追加した行のインデックスを取得
    $rowIndex = $dataGridView.Rows.Add($target.Name, $target.Host, $target.User)
    $dataGridView.Rows[$rowIndex].Tag = $target # 接続情報をタグに隠しておく
}

# 最初は一番上の項目が選択されている状態にする
if ($dataGridView.Rows.Count -gt 0) {
    $dataGridView.ClearSelection() # デフォルトの選択を一旦クリア
    $dataGridView.Rows[0].Selected = $true
    $dataGridView.CurrentCell = $dataGridView.Rows[0].Cells[0] # フォーカスも一番上に合わせる
}

# ダブルクリックイベント
$dataGridView.Add_CellDoubleClick({
    if ($dataGridView.CurrentRow) {
        $form.Tag = $dataGridView.CurrentRow.Tag
        $form.Close()
    }
})

# キーボードイベント
$dataGridView.Add_KeyDown({
    param($sender, $e)

    # Enterキーが押されたら接続を実行
    if ($e.KeyCode -eq 'Enter' -and $dataGridView.CurrentRow) {
        $form.Tag = $dataGridView.CurrentRow.Tag
        $form.Close()
    }

    # Qキーが押されたらキャンセル（何もせずに閉じる）
    if ($e.KeyCode -eq 'Q') {
        $form.Tag = $null # 接続処理が走らないようにタグを空にする
        $form.Close()
    }
})

# フォーム表示
$form.Controls.Add($dataGridView)

# フォームが表示された瞬間にDataGridViewにフォーカスを当てて、キーボード操作を即座に可能にする
$form.Add_Shown({ 
    $form.Activate()
    $dataGridView.Focus()
    $form.TopMost = $false
})

$form.ShowDialog() | Out-Null

# 接続実行
if ($form.Tag) {
    $s = $form.Tag
    Write-Host "Connecting to $($s.Name) ($($s.Host))..."
    ssh "$($s.User)@$($s.Host)" -p $($s.Port)
}
