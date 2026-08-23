unit XmlDocDemo.Samples;

{
  Every XMLDoc shape the renderer knows, one declaration each - hover them in
  VS Code and each hint shows what PasLsp.XmlDoc made of the block above it.
  See ..\README.md for what to look at first.

  This is a DEMO, not a test: the harness (clients\rad-studio\tests\
  LspClientSmoke.dpr, sections 5b/5c) is what pins the rendering. What this
  file is for is the part a harness cannot check - whether the result reads
  well in a real editor's hint window.
}

interface

uses
  System.SysUtils;

type
  /// <summary>Just enough of an attribute to have one in the file.</summary>
  DemoAttribute = class(TCustomAttribute)
  end;

  /// <summary>
  /// A person's name, split the way the demo needs it.
  /// </summary>
  /// <remarks>
  /// Remarks land in their own paragraph, after the summary - the order is
  /// fixed by the renderer, not by the order the tags appear in.
  /// </remarks>
  TPersonName = record
    /// <summary>Given name. A one-line summary is the common case.</summary>
    First: string;
    /// <summary>Family name.</summary>
    Last: string;
  end;

  /// <summary>What a greeting should sound like.</summary>
  TGreetingStyle = (
    /// <summary>Hello, First Last.</summary>
    gsFormal,
    /// <summary>Hi First!</summary>
    gsCasual);

  /// <summary>
  /// Builds greeting lines. The type's own doc block is what a hover over
  /// <c>TGreeter</c> anywhere in the project shows.
  /// </summary>
  /// <seealso cref="TGreetingStyle" />
  TGreeter = class
  private
    FStyle: TGreetingStyle;
  public
    /// <summary>Takes the style every later call will use.</summary>
    /// <param name="AStyle">formal or casual</param>
    constructor Create(AStyle: TGreetingStyle);

    /// <summary>
    /// Greets a person, in the style this greeter was created with.
    /// </summary>
    /// <param name="AName">
    /// the person to greet - a summary or a param text written across
    /// several source lines is collapsed into one paragraph, because the
    /// line breaks are the author's margin, not the author's meaning
    /// </param>
    /// <param name="AExcited">append an exclamation mark</param>
    /// <returns>the greeting line, ready to print</returns>
    /// <exception cref="EArgumentException">
    /// when the name has no first and no last part
    /// </exception>
    function Greet(const AName: TPersonName;
      AExcited: Boolean = False): string;

    /// <summary>The style in use. A property documents like anything else.</summary>
    property Style: TGreetingStyle read FStyle;
  end;

  /// <summary>A stack that documents its type parameter.</summary>
  /// <typeparam name="T">what the stack holds</typeparam>
  TDemoStack<T> = class
  public
    /// <summary>Pushes one item.</summary>
    /// <param name="AItem">the item</param>
    procedure Push(const AItem: T);
  end;

/// <summary>
/// Escapes are unescaped for display: a range is 0 &lt;= I &lt; Count, and
/// &amp; is an ampersand. An unterminated < in prose is left as text, because
/// a doc comment is prose someone typed and half of them have no tags at all.
/// </summary>
/// <returns>nothing interesting</returns>
function EscapesAndOddities: Integer;

{ Plain prose with NO tags at all: the whole block becomes the summary, so a
  declaration commented the old way still hovers usefully. }
/// This routine has been here since 2019 and nobody ever tagged it.
/// It still deserves a readable hint.
procedure UntaggedDoc;

/// <summary>
/// Attributes between the doc and the declaration are stepped over - docs
/// conventionally sit above them.
/// </summary>
[Demo]
procedure DocAboveAnAttribute;

/// <summary>
/// NOT attached to anything: a blank line breaks attachment, which is the
/// native IDE's rule too. Hovering ThisIsNotDocumented must show no
/// documentation at all - that is the point of this pair.
/// </summary>

procedure ThisIsNotDocumented;

const
  /// <summary>The answer. A const's value shows in the completion row; the
  /// doc shows in the hint.</summary>
  CAnswer = 42;

implementation

constructor TGreeter.Create(AStyle: TGreetingStyle);
begin
  inherited Create;
  FStyle := AStyle;
end;

function TGreeter.Greet(const AName: TPersonName;
  AExcited: Boolean = False): string;

  /// <summary>
  /// A nested routine keeps its OWN doc block - the climb to the declaration
  /// root stops at the enclosing routine's body.
  /// </summary>
  function Tail: string;
  begin
    if AExcited then
      Result := '!'
    else
      Result := '.';
  end;

begin
  if (AName.First = '') and (AName.Last = '') then
    raise EArgumentException.Create('a name with no parts');
  case FStyle of
    gsFormal:
      Result := Format('Hello, %s %s%s',
        [AName.First, AName.Last, Tail]);
  else
    Result := Format('Hi %s%s', [AName.First, Tail]);
  end;
end;

procedure TDemoStack<T>.Push(const AItem: T);
begin
  // The demo needs the declaration, not the container.
end;

function EscapesAndOddities: Integer;
begin
  Result := CAnswer;
end;

procedure UntaggedDoc;
begin
end;

procedure DocAboveAnAttribute;
begin
end;

procedure ThisIsNotDocumented;
begin
end;

end.
