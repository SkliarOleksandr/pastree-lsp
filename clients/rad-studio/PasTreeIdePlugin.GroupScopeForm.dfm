object PasTreeGroupScopeForm: TPasTreeGroupScopeForm
  Left = 0
  Top = 0
  BorderIcons = [biSystemMenu]
  BorderStyle = bsDialog
  Caption = 'Find All'
  ClientHeight = 291
  ClientWidth = 380
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  Position = poMainFormCenter
  TextHeight = 15
  object lblSubject: TLabel
    Left = 12
    Top = 12
    Width = 356
    Height = 15
    Caption = 'Search for:'
  end
  object edtSubject: TEdit
    Left = 12
    Top = 30
    Width = 356
    Height = 23
    Enabled = False
    TabOrder = 0
  end
  object lblPrompt: TLabel
    Left = 12
    Top = 62
    Width = 356
    Height = 15
    Caption = 'In these projects of the group (a cold one starts its server):'
  end
  object clbProjects: TCheckListBox
    Left = 12
    Top = 81
    Width = 356
    Height = 160
    ItemHeight = 17
    TabOrder = 1
  end
  object btnOK: TButton
    Left = 192
    Top = 252
    Width = 85
    Height = 27
    Caption = 'OK'
    Default = True
    ModalResult = 1
    TabOrder = 2
  end
  object btnCancel: TButton
    Left = 283
    Top = 252
    Width = 85
    Height = 27
    Cancel = True
    Caption = 'Cancel'
    ModalResult = 2
    TabOrder = 3
  end
end
