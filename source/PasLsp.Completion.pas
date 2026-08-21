unit PasLsp.Completion;

{
  THE COMPLETION SEAM (COMPLETION.md owns the plan): the ONLY unit that will
  ever call PasTree's completion API once it exists. Everything around it -
  the capability, the handler, the plugin plumbing, the harness section - is
  built against this unit's signature, so the library drops in HERE and
  nothing else moves.

  Until then it holds the interim provider: Delphi's reserved words, filtered
  by the identifier prefix left of the cursor. Deliberately visible by default
  (a plumbing stage must be seen working end-to-end, from the wire format to
  the IDE viewer), and deliberately word-list-dumb: it reads NOTHING but the
  request line, so nobody can mistake it for scope-aware completion. It gets
  one thing genuinely right, and that thing is the contract with clients: the
  REPLACE SPAN - the start/end columns of the partially-typed token - because
  LSP clients edit by textEdit range, and a provider that returns bare names
  forces every client to re-derive tokenization the provider already did.

  Positions are 1-based line / 1-based UTF-16 column (PasTree's convention);
  the caller converts from LSP's 0-based at the protocol boundary, same as
  every other handler.
}

interface

const
  // LSP CompletionItemKind - only the ones this unit emits today.
  lspItemKindKeyword = 14;

type
  TLspCompletionEntry = record
    ItemLabel: string;   // "Label" collides with the Delphi keyword list below
    Kind: Integer;       // lspItemKind*
    Detail: string;
  end;

  TLspCompletionAnswer = record
    Items: TArray<TLspCompletionEntry>;
    { The replace span: the partially-typed token every item replaces, on the
      request line. 1-based UTF-16 columns; From inclusive, To exclusive, so
      an empty token (nothing typed yet) has From = To = the cursor column. }
    ReplaceColFrom: Integer;
    ReplaceColTo: Integer;
    Provider: string;    // names the provider in the server's log line
  end;

{ The completion answer at a position in AText - the full document text, the
  live overlay when the file is open (the caller guarantees that; the model's
  copy is stale by definition mid-typing). Never raises; a position outside
  the text yields an empty answer with the span collapsed at the cursor. }
function CompleteAt(const AText: string; APasLine, APasCol: Integer):
  TLspCompletionAnswer;

implementation

uses
  System.SysUtils,
  PasLsp.Documents;

const
  { The reserved words of the Delphi language, per the current documentation's
    "Reserved words" list - not the directives (safecall, stdcall, ...), which
    are only special in context and would be noise everywhere else. }
  cReservedWords: array[0..63] of string = (
    'and', 'array', 'as', 'asm', 'begin', 'case', 'class', 'const',
    'constructor', 'destructor', 'dispinterface', 'div', 'do', 'downto',
    'else', 'end', 'except', 'exports', 'file', 'finalization', 'finally',
    'for', 'function', 'goto', 'if', 'implementation', 'in', 'inherited',
    'initialization', 'inline', 'interface', 'is', 'label', 'library', 'mod',
    'nil', 'not', 'object', 'of', 'or', 'packed', 'procedure', 'program',
    'property', 'raise', 'record', 'repeat', 'resourcestring', 'set', 'shl',
    'shr', 'string', 'then', 'threadvar', 'to', 'try', 'type', 'unit',
    'until', 'uses', 'var', 'while', 'with', 'xor');

function IsIdentChar(C: Char): Boolean;
begin
  Result := CharInSet(C, ['A'..'Z', 'a'..'z', '0'..'9', '_']);
end;

function CompleteAt(const AText: string; APasLine, APasCol: Integer):
  TLspCompletionAnswer;
var
  LCursor, LFrom, LLine, LChar: Integer;
  LPrefix, LWord: string;
  LEntry: TLspCompletionEntry;
begin
  Result := Default(TLspCompletionAnswer);
  Result.Provider := 'keywords';
  Result.ReplaceColFrom := APasCol;
  Result.ReplaceColTo := APasCol;

  // PositionToIndex speaks LSP's 0-based positions; convert and let its
  // clamping absorb a cursor past the end of the line or of the document.
  LLine := APasLine - 1;
  LChar := APasCol - 1;
  if (LLine < 0) or (LChar < 0) then
    Exit;
  LCursor := PositionToIndex(AText, LLine, LChar);

  // The token being typed: identifier characters immediately left of the
  // cursor. Identifiers cannot span lines, and PositionToIndex never lands
  // past one, so the backscan needs no line-break check of its own beyond
  // IsIdentChar saying no.
  LFrom := LCursor;
  while (LFrom > 1) and IsIdentChar(AText[LFrom - 1]) do
    Dec(LFrom);
  LPrefix := Copy(AText, LFrom, LCursor - LFrom);

  // The span in columns: the clamp above may have pulled the cursor left of
  // the requested column, so derive both ends from the indices actually used.
  Result.ReplaceColFrom := APasCol - Length(LPrefix);
  Result.ReplaceColTo := APasCol;

  for LWord in cReservedWords do
    if (LPrefix = '') or LWord.StartsWith(LPrefix, True) then
    begin
      LEntry.ItemLabel := LWord;
      LEntry.Kind := lspItemKindKeyword;
      LEntry.Detail := 'reserved word';
      Result.Items := Result.Items + [LEntry];
    end;
end;

end.
