object PasTreeSettingsForm: TPasTreeSettingsForm
  Left = 0
  Top = 0
  BorderIcons = [biSystemMenu]
  BorderStyle = bsDialog
  Caption = 'PasTree Settings'
  ClientHeight = 386
  ClientWidth = 462
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  Position = poMainFormCenter
  TextHeight = 15
  object bvlHeader: TBevel
    Left = 0
    Top = 92
    Width = 462
    Height = 2
    Align = alTop
    Shape = bsTopLine
    ExplicitWidth = 460
  end
  object pnlHeader: TPanel
    Left = 0
    Top = 0
    Width = 462
    Height = 92
    Align = alTop
    BevelOuter = bvNone
    ParentBackground = False
    TabOrder = 0
    object lblProduct: TLabel
      Left = 16
      Top = 14
      Width = 118
      Height = 25
      Caption = 'PasTree LSP'
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clWindowText
      Font.Height = -19
      Font.Name = 'Segoe UI'
      Font.Style = [fsBold]
      ParentFont = False
    end
    object lblVersion: TLabel
      Left = 18
      Top = 45
      Width = 44
      Height = 15
      Caption = 'Version'
    end
    object lblBuilt: TLabel
      Left = 18
      Top = 64
      Width = 27
      Height = 15
      Caption = 'Built'
    end
    object lnkHome: TLinkLabel
      Left = 197
      Top = 45
      Width = 247
      Height = 19
      Caption =
        '<a href="https://github.com/SkliarOleksandr/pastree-lsp">github.' +
        'com/SkliarOleksandr/pastree-lsp</a>'
      TabOrder = 0
      OnLinkClick = lnkHomeLinkClick
    end
  end
  object gbOverrides: TGroupBox
    Left = 16
    Top = 108
    Width = 430
    Height = 222
    Caption = ' Overrides '
    TabOrder = 1
    object lblStructureViewHint: TLabel
      Left = 35
      Top = 45
      Width = 377
      Height = 30
      Caption =
        'Fills the Structure pane from the analysis. Off leaves the pane t' +
        'o the IDE'#39's own provider.'
      WordWrap = True
    end
    object lblDeclImplToggleHint: TLabel
      Left = 35
      Top = 110
      Width = 377
      Height = 30
      Caption =
        'Off hands the keystroke back to the IDE, which runs its own decla' +
        'ration/implementation jump.'
      WordWrap = True
    end
    object lblRenameHint: TLabel
      Left = 35
      Top = 175
      Width = 377
      Height = 30
      Caption =
        'Renames a symbol across the project and lists every changed line ' +
        'in its own Messages tab. Off hides the command entirely.'
      WordWrap = True
    end
    object chkStructureView: TCheckBox
      Left = 16
      Top = 24
      Width = 396
      Height = 17
      Caption = 'Structure pane outline'
      Checked = True
      State = cbChecked
      TabOrder = 0
    end
    object chkDeclImplToggle: TCheckBox
      Left = 16
      Top = 89
      Width = 396
      Height = 17
      Caption = 'Ctrl+Shift+Up / Ctrl+Shift+Down declaration'#8596'implementation jump'
      Checked = True
      State = cbChecked
      TabOrder = 1
    end
    object chkRename: TCheckBox
      Left = 16
      Top = 154
      Width = 396
      Height = 17
      Caption = 'Rename (Ctrl+Shift+E)'
      Checked = True
      State = cbChecked
      TabOrder = 2
    end
  end
  object btnOK: TButton
    Left = 270
    Top = 346
    Width = 85
    Height = 27
    Caption = 'OK'
    Default = True
    ModalResult = 1
    TabOrder = 2
  end
  object btnCancel: TButton
    Left = 361
    Top = 346
    Width = 85
    Height = 27
    Cancel = True
    Caption = 'Cancel'
    ModalResult = 2
    TabOrder = 3
  end
end
