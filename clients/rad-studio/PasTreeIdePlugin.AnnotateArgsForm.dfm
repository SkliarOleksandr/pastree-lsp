object PasTreeAnnotateArgsForm: TPasTreeAnnotateArgsForm
  Left = 0
  Top = 0
  BorderIcons = [biSystemMenu]
  BorderStyle = bsDialog
  Caption = 'Annotate Arguments'
  ClientHeight = 257
  ClientWidth = 360
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  Position = poMainFormCenter
  TextHeight = 15
  object grpScope: TGroupBox
    Left = 12
    Top = 12
    Width = 336
    Height = 128
    Caption = ' Annotate with {ParamName:}'
    TabOrder = 0
    object rbAll: TRadioButton
      Left = 16
      Top = 24
      Width = 300
      Height = 17
      Caption = 'All arguments'
      Checked = True
      TabOrder = 0
      TabStop = True
    end
    object rbAnonymous: TRadioButton
      Left = 16
      Top = 48
      Width = 300
      Height = 17
      Caption = 'Only literals and expressions'
      TabOrder = 1
    end
    object rbCurrent: TRadioButton
      Left = 16
      Top = 72
      Width = 300
      Height = 17
      Caption = 'Only the argument at the caret'
      TabOrder = 2
    end
    object rbNone: TRadioButton
      Left = 16
      Top = 96
      Width = 300
      Height = 17
      Caption = 'None'
      TabOrder = 3
    end
  end
  object chkByRef: TCheckBox
    Left = 28
    Top = 152
    Width = 320
    Height = 17
    Caption = 'Mark var / out parameters with {var} / {out}'
    Checked = True
    State = cbChecked
    TabOrder = 1
  end
  object chkOneArgPerLine: TCheckBox
    Left = 28
    Top = 176
    Width = 320
    Height = 17
    Caption = 'Put each argument on its own line'
    TabOrder = 2
  end
  object btnOK: TButton
    Left = 172
    Top = 216
    Width = 85
    Height = 27
    Caption = 'OK'
    Default = True
    ModalResult = 1
    TabOrder = 3
  end
  object btnCancel: TButton
    Left = 263
    Top = 216
    Width = 85
    Height = 27
    Cancel = True
    Caption = 'Cancel'
    ModalResult = 2
    TabOrder = 4
  end
end
