//
//  DOTerminalViewController.m
//  Dopamine
//
//  Runs zsh from the bootstrap inside a pseudo terminal (pty) as root.
//

#import "DOTerminalViewController.h"

#import <sys/types.h>
#import <sys/wait.h>
#import <sys/ioctl.h>
#import <sys/stat.h>
#import <termios.h>
#import <fcntl.h>
#import <errno.h>
#import <signal.h>
#import <unistd.h>
#import <spawn.h>
#import <util.h>

#import "DOEnvironmentManager.h"
// util.h from libjailbreak declares the POSIX_SPAWN persona helpers used to
// launch the shell as root. It also pulls in <spawn.h>.
#import <libjailbreak/util.h>

extern char **environ;

#define DO_TERM_DEFAULT_COLS 80
#define DO_TERM_DEFAULT_ROWS 24
#define DO_TERM_MAX_COLS 400
#define DO_TERM_MAX_ROWS 200

#pragma mark - Screen buffer

typedef struct {
    unichar *chars;
    int width;
    int height;
    int cursorX;
    int cursorY;
} DOTermScreen;

static void DO_ScreenInit(DOTermScreen *s, int cols, int rows)
{
    s->width = cols;
    s->height = rows;
    s->cursorX = 0;
    s->cursorY = 0;
    s->chars = (unichar *)calloc((size_t)(cols * rows), sizeof(unichar));
    if (s->chars) {
        for (int i = 0; i < cols * rows; i++) s->chars[i] = ' ';
    }
}

static void DO_ScreenFree(DOTermScreen *s)
{
    if (s->chars) { free(s->chars); s->chars = NULL; }
}

static void DO_ScreenClear(DOTermScreen *s)
{
    if (!s->chars) return;
    for (int i = 0; i < s->width * s->height; i++) s->chars[i] = ' ';
    s->cursorX = 0;
    s->cursorY = 0;
}

static void DO_ScreenScrollUp(DOTermScreen *s)
{
    if (!s->chars || s->height <= 1) return;
    int w = s->width, h = s->height;
    memmove(s->chars, s->chars + w, (size_t)(w * (h - 1)) * sizeof(unichar));
    for (int i = 0; i < w; i++) s->chars[w * (h - 1) + i] = ' ';
}

static void DO_ScreenNewline(DOTermScreen *s)
{
    if (!s->chars) return;
    if (s->cursorY >= s->height - 1) {
        DO_ScreenScrollUp(s);
        s->cursorY = s->height - 1;
    } else {
        s->cursorY++;
    }
}

static void DO_ScreenPutChar(DOTermScreen *s, unichar c)
{
    if (!s->chars) return;
    if (s->cursorX >= s->width) { s->cursorX = 0; DO_ScreenNewline(s); }
    if (s->cursorY < 0) s->cursorY = 0;
    if (s->cursorY >= s->height) s->cursorY = s->height - 1;
    s->chars[s->cursorY * s->width + s->cursorX] = c;
    s->cursorX++;
}

static void DO_ScreenCSI(DOTermScreen *s, const int *params, int nparams, char final)
{
    int p1 = (nparams >= 1 && params[0] > 0) ? params[0] : 1;
    int p2 = (nparams >= 2 && params[1] > 0) ? params[1] : 1;

    switch (final) {
        case 'A':
            s->cursorY -= p1;
            if (s->cursorY < 0) s->cursorY = 0;
            break;
        case 'B':
            s->cursorY += p1;
            if (s->cursorY > s->height - 1) s->cursorY = s->height - 1;
            break;
        case 'C':
            s->cursorX += p1;
            if (s->cursorX > s->width - 1) s->cursorX = s->width - 1;
            break;
        case 'D':
            s->cursorX -= p1;
            if (s->cursorX < 0) s->cursorX = 0;
            break;
        case 'G':
            s->cursorX = p1 - 1;
            if (s->cursorX < 0) s->cursorX = 0;
            if (s->cursorX > s->width - 1) s->cursorX = s->width - 1;
            break;
        case 'H':
        case 'f':
            s->cursorY = p1 - 1;
            s->cursorX = p2 - 1;
            if (s->cursorY < 0) s->cursorY = 0;
            if (s->cursorY > s->height - 1) s->cursorY = s->height - 1;
            if (s->cursorX < 0) s->cursorX = 0;
            if (s->cursorX > s->width - 1) s->cursorX = s->width - 1;
            break;
        case 'J': {
            int mode = (nparams >= 1) ? params[0] : 0;
            if (mode == 0) {
                for (int x = s->cursorX; x < s->width; x++) s->chars[s->cursorY * s->width + x] = ' ';
                for (int y = s->cursorY + 1; y < s->height; y++)
                    for (int x = 0; x < s->width; x++) s->chars[y * s->width + x] = ' ';
            } else if (mode == 1) {
                for (int y = 0; y < s->cursorY; y++)
                    for (int x = 0; x < s->width; x++) s->chars[y * s->width + x] = ' ';
                for (int x = 0; x <= s->cursorX && x < s->width; x++) s->chars[s->cursorY * s->width + x] = ' ';
            } else {
                DO_ScreenClear(s);
            }
            break;
        }
        case 'K': {
            int mode = (nparams >= 1) ? params[0] : 0;
            int row = s->cursorY * s->width;
            if (mode == 0) {
                for (int x = s->cursorX; x < s->width; x++) s->chars[row + x] = ' ';
            } else if (mode == 1) {
                for (int x = 0; x <= s->cursorX && x < s->width; x++) s->chars[row + x] = ' ';
            } else {
                for (int x = 0; x < s->width; x++) s->chars[row + x] = ' ';
            }
            break;
        }
        case 'P': {
            int row = s->cursorY * s->width;
            int n = p1;
            if (n > s->width - s->cursorX) n = s->width - s->cursorX;
            memmove(s->chars + row + s->cursorX, s->chars + row + s->cursorX + n,
                    (size_t)(s->width - s->cursorX - n) * sizeof(unichar));
            for (int x = s->width - n; x < s->width; x++) s->chars[row + x] = ' ';
            break;
        }
        case 'X': {
            int row = s->cursorY * s->width;
            int n = p1;
            if (n > s->width - s->cursorX) n = s->width - s->cursorX;
            for (int x = s->cursorX; x < s->cursorX + n; x++) s->chars[row + x] = ' ';
            break;
        }
        case 'h':
        case 'l':
            if (nparams >= 1 && params[0] == 1049) DO_ScreenClear(s);
            break;
        default:
            break;
    }
}

#pragma mark - Terminal view

@interface DOTerminalView : UIView
@property (nonatomic) DOTermScreen screen;
@property (nonatomic, strong) UIFont *termFont;
@property (nonatomic, strong) NSMutableData *pendingBytes;
@property (nonatomic, copy) void (^onResize)(int cols, int rows);
- (void)feedBytes:(const uint8_t *)bytes length:(NSUInteger)length;
- (void)resetScreen;
- (int)columns;
- (int)rows;
@end

@implementation DOTerminalView {
    int _pState;   // 0 normal, 1 ESC, 2 CSI, 3 OSC, 4 ESC-in-OSC, 5 charset
    int _params[16];
    int _nparams;
    int _curParam;
    BOOL _hasCurParam;
    int _lastCols;
    int _lastRows;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        _termFont = [UIFont monospacedSystemFontOfSize:11.0 weight:UIFontWeightRegular];
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.contentMode = UIViewContentModeRedraw;
        self.multipleTouchEnabled = YES;
        _pendingBytes = [NSMutableData data];
        DO_ScreenInit(&_screen, DO_TERM_DEFAULT_COLS, DO_TERM_DEFAULT_ROWS);
        _lastCols = DO_TERM_DEFAULT_COLS;
        _lastRows = DO_TERM_DEFAULT_ROWS;
    }
    return self;
}

- (void)dealloc
{
    DO_ScreenFree(&_screen);
}

- (int)columns { return _screen.width; }
- (int)rows { return _screen.height; }

- (void)resetScreen
{
    DO_ScreenClear(&_screen);
    _pState = 0;
    _nparams = 0;
    _curParam = 0;
    _hasCurParam = NO;
    [self setNeedsDisplay];
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    [self recalculateSize];
}

- (void)recalculateSize
{
    CGSize charSize = [@"M" sizeWithAttributes:@{NSFontAttributeName : self.termFont}];
    if (charSize.width <= 0 || charSize.height <= 0) return;
    if (self.bounds.size.width <= 0 || self.bounds.size.height <= 0) return;

    int cols = (int)floor(self.bounds.size.width / charSize.width);
    int rows = (int)floor(self.bounds.size.height / charSize.height);
    if (cols < 20) cols = 20;
    if (rows < 8) rows = 8;
    if (cols > DO_TERM_MAX_COLS) cols = DO_TERM_MAX_COLS;
    if (rows > DO_TERM_MAX_ROWS) rows = DO_TERM_MAX_ROWS;

    if (cols == _lastCols && rows == _lastRows) return;
    _lastCols = cols;
    _lastRows = rows;

    DOTermScreen next;
    DO_ScreenInit(&next, cols, rows);
    if (next.chars) {
        int copyRows = MIN(rows, _screen.height);
        int copyCols = MIN(cols, _screen.width);
        if (_screen.chars && _screen.width > 0) {
            for (int y = 0; y < copyRows; y++)
                for (int x = 0; x < copyCols; x++)
                    next.chars[y * cols + x] = _screen.chars[y * _screen.width + x];
            next.cursorX = MIN(_screen.cursorX, cols - 1);
            next.cursorY = MIN(_screen.cursorY, rows - 1);
        }
        DO_ScreenFree(&_screen);
        _screen = next;
    }

    if (self.onResize) self.onResize(cols, rows);
    [self setNeedsDisplay];
}

#pragma mark Parsing

- (void)feedBytes:(const uint8_t *)bytes length:(NSUInteger)length
{
    if (!bytes || length == 0) return;
    if (!self.pendingBytes) self.pendingBytes = [NSMutableData data];
    [self.pendingBytes appendBytes:bytes length:length];

    NSUInteger consumed = 0;
    NSString *str = [self decodeUTF8:self.pendingBytes consumed:&consumed];
    if (consumed > 0) {
        [self.pendingBytes replaceBytesInRange:NSMakeRange(0, consumed) withBytes:NULL length:0];
    }
    if (str.length == 0) return;
    [self consumeString:str];
    [self setNeedsDisplay];
}

- (NSString *)decodeUTF8:(NSMutableData *)data consumed:(NSUInteger *)consumed
{
    const uint8_t *p = data.bytes;
    NSUInteger len = data.length;
    NSUInteger i = 0;
    while (i < len) {
        uint8_t c = p[i];
        NSUInteger need = 0;
        if (c < 0x80) need = 0;
        else if ((c & 0xE0) == 0xC0) need = 1;
        else if ((c & 0xF0) == 0xE0) need = 2;
        else if ((c & 0xF8) == 0xF0) need = 3;
        else { i++; continue; }
        if (i + need >= len) break;
        i += need + 1;
    }

    *consumed = i;
    if (i == 0) return @"";

    NSString *s = [[NSString alloc] initWithBytes:p length:i encoding:NSUTF8StringEncoding];
    if (!s) s = [[NSString alloc] initWithBytes:p length:i encoding:NSISOLatin1StringEncoding];
    return s ?: @"";
}

- (void)consumeString:(NSString *)str
{
    NSUInteger n = str.length;
    if (n == 0) return;
    unichar *buf = (unichar *)malloc(n * sizeof(unichar));
    if (!buf) return;
    [str getCharacters:buf range:NSMakeRange(0, n)];

    for (NSUInteger i = 0; i < n; i++) {
        unichar c = buf[i];

        if (_pState == 0) {
            if (c == 0x1B) {
                _pState = 1;
            } else if (c == '\r') {
                _screen.cursorX = 0;
            } else if (c == '\n') {
                DO_ScreenNewline(&_screen);
            } else if (c == '\b') {
                if (_screen.cursorX > 0) _screen.cursorX--;
            } else if (c == '\t') {
                int next = ((_screen.cursorX / 8) + 1) * 8;
                while (_screen.cursorX < next) DO_ScreenPutChar(&_screen, ' ');
            } else if (c < 0x20) {
                // bell and other control characters are ignored
            } else {
                DO_ScreenPutChar(&_screen, c);
            }
            continue;
        }

        if (_pState == 1) {
            if (c == '[') {
                _pState = 2;
                _nparams = 0;
                _curParam = 0;
                _hasCurParam = NO;
            } else if (c == ']') {
                _pState = 3;
            } else if (c == '(' || c == ')') {
                _pState = 5;
            } else if (c == 'M') {
                if (_screen.cursorY <= 0) {
                    int w = _screen.width, h = _screen.height;
                    if (h > 1) {
                        memmove(_screen.chars + w, _screen.chars, (size_t)(w * (h - 1)) * sizeof(unichar));
                        for (int x = 0; x < w; x++) _screen.chars[x] = ' ';
                    }
                } else {
                    _screen.cursorY--;
                }
                _pState = 0;
            } else {
                _pState = 0;
            }
            continue;
        }

        if (_pState == 2) {
            if (c >= '0' && c <= '9') {
                _curParam = _curParam * 10 + (int)(c - '0');
                _hasCurParam = YES;
            } else if (c == ';' || c == ':') {
                if (_nparams < 15) _params[_nparams++] = _hasCurParam ? _curParam : 0;
                _curParam = 0;
                _hasCurParam = NO;
            } else if (c == '?') {
                // private mode marker, skip
            } else if (c >= 0x20 && c <= 0x2F) {
                // intermediate byte, skip
            } else {
                if (_nparams < 15) _params[_nparams++] = _hasCurParam ? _curParam : 0;
                DO_ScreenCSI(&_screen, _params, _nparams, (char)c);
                _pState = 0;
                _nparams = 0;
            }
            continue;
        }

        if (_pState == 3) {
            if (c == 0x07) _pState = 0;
            else if (c == 0x1B) _pState = 4;
            continue;
        }

        // states 4 and 5 both just consume one byte
        _pState = 0;
    }
    free(buf);
}

#pragma mark Drawing

- (void)drawRect:(CGRect)rect
{
    if (!_screen.chars) return;

    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;

    CGSize charSize = [@"M" sizeWithAttributes:@{NSFontAttributeName : self.termFont}];
    CGFloat cw = charSize.width;
    CGFloat ch = charSize.height;
    if (cw <= 0 || ch <= 0) return;

    NSDictionary *attrs = @{
        NSFontAttributeName : self.termFont,
        NSForegroundColorAttributeName : [UIColor whiteColor],
    };

    NSMutableString *line = [NSMutableString stringWithCapacity:(NSUInteger)_screen.width];
    for (int y = 0; y < _screen.height; y++) {
        int trailing = _screen.width;
        while (trailing > 0 && _screen.chars[y * _screen.width + trailing - 1] == ' ') trailing--;
        if (trailing == 0) continue;

        [line setString:@""];
        for (int x = 0; x < trailing; x++) {
            unichar c = _screen.chars[y * _screen.width + x];
            if (c == 0 || c < 0x20) c = ' ';
            [line appendFormat:@"%C", c];
        }
        [line drawAtPoint:CGPointMake(0, y * ch) withAttributes:attrs];
    }

    // Cursor block, drawn through the explicit context.
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:1.0 alpha:0.35].CGColor);
    CGContextFillRect(ctx, CGRectMake(_screen.cursorX * cw, _screen.cursorY * ch, cw, ch));
}

@end

#pragma mark - View controller

@interface DOTerminalViewController () <UITextViewDelegate>
@property (nonatomic, strong) DOTerminalView *termView;
@property (nonatomic, strong) UIView *containerView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UITextView *inputProxy;
@property (nonatomic, assign) pid_t childPid;
@property (nonatomic, assign) int masterFD;
@property (nonatomic, strong) dispatch_source_t readSource;
@property (nonatomic, assign) BOOL shellStopped;
// Last grid size reported by the view. Kept so the pty can be sized correctly
// at spawn time, before the first resize callback reaches a live shell.
@property (nonatomic, assign) int pendingCols;
@property (nonatomic, assign) int pendingRows;
@end

@implementation DOTerminalViewController

#pragma mark Availability

+ (NSString *)zshPath
{
    // Try the resolved jailbreak root first. JBROOT_PATH turns a bootstrap
    // relative path into the real one under /private/preboot, which is what we
    // want when /var/jb is not what we expect it to be.
    NSString *rootedPath = JBROOT_PATH(@"/bin/zsh");
    if (rootedPath.length && [[NSFileManager defaultManager] isExecutableFileAtPath:rootedPath]) {
        return rootedPath;
    }

    // Fallbacks: the bootstrap symlink and the legacy unprefixed location.
    NSArray<NSString *> *candidates = @[ @"/var/jb/bin/zsh", @"/bin/zsh" ];
    for (NSString *path in candidates) {
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:path]) return path;
    }
    return nil;
}

+ (BOOL)isAvailable
{
    if (![[DOEnvironmentManager sharedManager] isJailbroken]) return NO;
    return [self zshPath] != nil;
}

#pragma mark Lifecycle

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.title = @"Terminal";
    self.view.backgroundColor = [UIColor blackColor];

    _containerView = [[UIView alloc] init];
    _containerView.translatesAutoresizingMaskIntoConstraints = NO;
    _containerView.backgroundColor = [UIColor blackColor];
    _containerView.clipsToBounds = YES;
    [self.view addSubview:_containerView];

    _termView = [[DOTerminalView alloc] initWithFrame:CGRectZero];
    _termView.translatesAutoresizingMaskIntoConstraints = NO;
    [_containerView addSubview:_termView];

    _statusLabel = [[UILabel alloc] init];
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _statusLabel.font = [UIFont monospacedSystemFontOfSize:11.0 weight:UIFontWeightRegular];
    _statusLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    _statusLabel.backgroundColor = [UIColor clearColor];
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.numberOfLines = 0;
    _statusLabel.hidden = YES;
    [_containerView addSubview:_statusLabel];

    // An invisible text view keeps the keyboard up and gives us multi-character
    // input (paste) for free.
    _inputProxy = [[UITextView alloc] initWithFrame:CGRectZero];
    _inputProxy.translatesAutoresizingMaskIntoConstraints = NO;
    _inputProxy.backgroundColor = [UIColor clearColor];
    _inputProxy.textColor = [UIColor clearColor];
    _inputProxy.tintColor = [UIColor clearColor];
    _inputProxy.autocorrectionType = UITextAutocorrectionTypeNo;
    _inputProxy.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _inputProxy.spellCheckingType = UITextSpellCheckingTypeNo;
    if (@available(iOS 11.0, *)) {
        _inputProxy.smartQuotesType = UITextSmartQuotesTypeNo;
        _inputProxy.smartDashesType = UITextSmartDashesTypeNo;
    }
    _inputProxy.keyboardAppearance = UIKeyboardAppearanceDark;
    _inputProxy.delegate = self;
    [self.view addSubview:_inputProxy];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
    [_containerView addGestureRecognizer:tap];

    [self setupKeyboardToolbar];

    [NSLayoutConstraint activateConstraints:@[
        [_containerView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [_containerView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_containerView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_containerView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [_termView.topAnchor constraintEqualToAnchor:_containerView.topAnchor constant:4],
        [_termView.leadingAnchor constraintEqualToAnchor:_containerView.leadingAnchor constant:6],
        [_termView.trailingAnchor constraintEqualToAnchor:_containerView.trailingAnchor constant:-6],
        [_termView.bottomAnchor constraintEqualToAnchor:_containerView.bottomAnchor constant:-4],

        [_statusLabel.centerXAnchor constraintEqualToAnchor:_containerView.centerXAnchor],
        [_statusLabel.centerYAnchor constraintEqualToAnchor:_containerView.centerYAnchor],
        [_statusLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:_containerView.leadingAnchor constant:20],
        [_statusLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_containerView.trailingAnchor constant:-20],

        [_inputProxy.widthAnchor constraintEqualToConstant:1],
        [_inputProxy.heightAnchor constraintEqualToConstant:1],
        [_inputProxy.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:-2],
        [_inputProxy.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:-2],
    ]];

    __weak typeof(self) weakSelf = self;
    _termView.onResize = ^(int cols, int rows) {
        [weakSelf applyWindowSizeCols:cols rows:rows];
    };
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    if (_childPid == 0 && !_shellStopped) [self startShell];
    [_inputProxy becomeFirstResponder];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [_inputProxy resignFirstResponder];

    // Leave the pty as soon as the user navigates away. UIKit sets
    // isMovingFromParentViewController before viewWillDisappear runs for a
    // navigation pop, so this is the reliable place to tear the shell down.
    if (self.isMovingFromParentViewController || self.isBeingDismissed) {
        [self stopShell];
    }
}

- (void)didMoveToParentViewController:(UIViewController *)parent
{
    [super didMoveToParentViewController:parent];
    // Belt and braces: getting detached from the navigation stack always means
    // the shell should go away.
    if (parent == nil) [self stopShell];
}

- (void)dealloc
{
    [self stopShell];
}

#pragma mark Keyboard toolbar

- (UIBarButtonItem *)toolbarItemWithTitle:(NSString *)title action:(SEL)action
{
    return [[UIBarButtonItem alloc] initWithTitle:title style:UIBarButtonItemStylePlain target:self action:action];
}

- (void)setupKeyboardToolbar
{
    UIToolbar *toolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 0, 44)];
    toolbar.barStyle = UIBarStyleBlack;

    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(dismissKeyboard)];

    toolbar.items = @[
        [self toolbarItemWithTitle:@"esc" action:@selector(sendEsc)],
        [self toolbarItemWithTitle:@"tab" action:@selector(sendTab)],
        [self toolbarItemWithTitle:@"^C" action:@selector(sendCtrlC)],
        flex,
        [self toolbarItemWithTitle:@"◀" action:@selector(sendLeft)],
        [self toolbarItemWithTitle:@"▲" action:@selector(sendUp)],
        [self toolbarItemWithTitle:@"▼" action:@selector(sendDown)],
        [self toolbarItemWithTitle:@"▶" action:@selector(sendRight)],
        flex,
        done
    ];
    [toolbar sizeToFit];
    _inputProxy.inputAccessoryView = toolbar;
}

- (void)dismissKeyboard { [_inputProxy resignFirstResponder]; }
- (void)handleTap:(UITapGestureRecognizer *)sender { [_inputProxy becomeFirstResponder]; }
- (void)sendEsc { [self writeBytes:(const uint8_t *)"\x1b" length:1]; }
- (void)sendTab { [self writeBytes:(const uint8_t *)"\t" length:1]; }
- (void)sendCtrlC { uint8_t c = 0x03; [self writeBytes:&c length:1]; }
- (void)sendUp { [self writeBytes:(const uint8_t *)"\x1b[A" length:3]; }
- (void)sendDown { [self writeBytes:(const uint8_t *)"\x1b[B" length:3]; }
- (void)sendRight { [self writeBytes:(const uint8_t *)"\x1b[C" length:3]; }
- (void)sendLeft { [self writeBytes:(const uint8_t *)"\x1b[D" length:3]; }

#pragma mark Shell lifecycle

- (void)showStatus:(NSString *)text
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.text = text;
        self.statusLabel.hidden = (text.length == 0);
    });
}

- (void)startShell
{
    NSString *zshPath = [[self class] zshPath];
    if (!zshPath) {
        [self showStatus:@"zsh not found.\n\nJailbreak the device and install the bootstrap first."];
        return;
    }

    int masterFD = -1;
    int slaveFD = -1;
    if (openpty(&masterFD, &slaveFD, NULL, NULL, NULL) != 0) {
        [self showStatus:[NSString stringWithFormat:@"openpty failed: %s", strerror(errno)]];
        return;
    }

    // Put the pty into a sane raw-ish state for an interactive shell.
    struct termios tio;
    if (tcgetattr(slaveFD, &tio) == 0) {
        cfmakeraw(&tio);
        tio.c_oflag |= OPOST | ONLCR;
        tio.c_iflag |= ICRNL | IXON;
        tio.c_cflag |= CS8 | CREAD | CLOCAL;
        tio.c_lflag |= ISIG | ICANON | ECHO | ECHOE | ECHOK | IEXTEN;
        tio.c_cc[VINTR]  = 0x03;
        tio.c_cc[VQUIT]  = 0x1C;
        tio.c_cc[VERASE] = 0x7F;
        tio.c_cc[VKILL]  = 0x15;
        tio.c_cc[VEOF]   = 0x04;
        tio.c_cc[VSTART] = 0x11;
        tio.c_cc[VSTOP]  = 0x13;
        tio.c_cc[VSUSP]  = 0x1A;
        tcsetattr(slaveFD, TCSANOW, &tio);
    }

    int cols = _pendingCols > 0 ? _pendingCols : [_termView columns];
    int rows = _pendingRows > 0 ? _pendingRows : [_termView rows];
    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_row = (unsigned short)rows;
    ws.ws_col = (unsigned short)cols;
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;
    ioctl(slaveFD, TIOCSWINSZ, &ws);

    // Minimal environment. PATH starts with the bootstrap binaries so that
    // everything the bootstrap provides is reachable.
    NSArray<NSString *> *envLines = @[
        @"TERM=xterm-256color",
        @"HOME=/var/mobile",
        @"USER=mobile",
        @"LOGNAME=mobile",
        @"SHELL=/var/jb/bin/zsh",
        @"PATH=/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/bin:/var/jb/sbin:/usr/bin:/bin:/usr/sbin:/sbin",
        @"LANG=en_US.UTF-8",
    ];
    const char *envp[32];
    int envCount = 0;
    for (NSString *line in envLines) {
        if (envCount >= 31) break;
        envp[envCount++] = strdup(line.UTF8String);
    }
    envp[envCount] = NULL;

    const char *arg0 = zshPath.UTF8String;
    const char *argv[] = { arg0, "-l", "-i", NULL };

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, slaveFD, STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&actions, slaveFD, STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, slaveFD, STDERR_FILENO);

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    sigset_t emptyMask;
    sigemptyset(&emptyMask);
    posix_spawnattr_setsigmask(&attr, &emptyMask);
    // POSIX_SPAWN_SETSIGMASK gives the shell a clean signal mask. Note that
    // POSIX_SPAWN_SETSID does not exist in the Apple SDK, and zsh becomes a
    // session leader on its own once it takes over the pty.
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSIGMASK);

    __block pid_t pid = 0;
    __block int spawnResult = -1;

    // Spawn the shell as root.
    //
    // DOEnvironmentManager's runAsRoot: block is the usual way of getting root,
    // but it must be left on the same runloop turn it was entered (iOS 17+
    // panics otherwise). An interactive shell lives for a long time, so instead
    // we use the persona attributes from libjailbreak's util.h, which is how
    // libjailbreak itself launches root processes (see __exec_cmd_internal_va
    // in BaseBin/libjailbreak/src/util.c). The process is created as root right
    // away and the app never holds root itself.
    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);
    spawnResult = posix_spawn(&pid, arg0, &actions, &attr, (char *const *)argv, (char *const *)envp);

    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    for (int i = 0; i < envCount; i++) free((void *)envp[i]);

    if (spawnResult != 0) {
        close(masterFD);
        close(slaveFD);
        [self showStatus:[NSString stringWithFormat:@"posix_spawn failed: %s", strerror(spawnResult)]];
        return;
    }

    close(slaveFD);

    _childPid = pid;
    _masterFD = masterFD;

    [self startReadingFromMaster];
}

- (void)startReadingFromMaster
{
    int fd = _masterFD;
    if (fd < 0) return;

    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);

    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0,
                                                      dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0));
    if (!source) {
        [self showStatus:@"Failed to create read source."];
        return;
    }
    _readSource = source;

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(source, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        // Read whatever is pending without blocking. The descriptor stays in
        // blocking mode here on purpose: a blocking read on a pty master always
        // returns at least one byte, and the source only fires when it is
        // readable. O_NONBLOCK would be unsafe here because the parent may own
        // other descriptors that share the same file description table entry.
        int readFD = self.masterFD;
        if (readFD < 0) return;
        if (self.shellStopped) return;

        // Blocks cannot capture C arrays, so the buffer is allocated per read
        // and handed to the main queue as an object.
        uint8_t *buffer = malloc(8192);
        if (!buffer) return;
        ssize_t n = read(readFD, buffer, 8192);
        if (n > 0) {
            NSData *chunk = [NSData dataWithBytesNoCopy:buffer length:(NSUInteger)n freeWhenDone:YES];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.termView feedBytes:(const uint8_t *)chunk.bytes length:chunk.length];
            });
        } else {
            free(buffer);
            if (n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR)) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self handleShellExit];
                });
            }
        }
    });

    dispatch_source_set_cancel_handler(source, ^{
        // Socket closed; nothing else to clean up here.
    });

    dispatch_resume(source);
}

- (void)handleShellExit
{
    if (_shellStopped) return;
    _shellStopped = YES;

    if (_readSource) {
        dispatch_source_cancel(_readSource);
        _readSource = nil;
    }
    if (_masterFD >= 0) {
        close(_masterFD);
        _masterFD = -1;
    }

    if (_childPid > 0) {
        pid_t pid = _childPid;
        _childPid = 0;
        int status = 0;
        // Reap without blocking; the shell is on its way out but might need a
        // few milliseconds to actually become a zombie.
        for (int i = 0; i < 20; i++) {
            pid_t r = waitpid(pid, &status, WNOHANG);
            if (r == pid || (r < 0 && errno == ECHILD)) break;
            usleep(20 * 1000);
        }
    }

    [self showStatus:@"[shell exited]"];
}

- (void)stopShell
{
    if (_shellStopped) return;
    _shellStopped = YES;

    if (_readSource) {
        dispatch_source_cancel(_readSource);
        _readSource = nil;
    }

    // Close our end of the pty first: that delivers SIGHUP to the foreground
    // process group of the terminal, which is the normal way an interactive
    // shell learns that its terminal went away.
    if (_masterFD >= 0) {
        close(_masterFD);
        _masterFD = -1;
    }

    if (_childPid > 0) {
        pid_t pid = _childPid;
        _childPid = 0;

        // Give zsh a moment to exit on its own, then insist.
        int status = 0;
        BOOL reaped = NO;
        for (int i = 0; i < 10; i++) {
            pid_t r = waitpid(pid, &status, WNOHANG);
            if (r == pid || (r < 0 && errno == ECHILD)) { reaped = YES; break; }
            usleep(30 * 1000);
        }
        if (!reaped) {
            kill(pid, SIGTERM);
            for (int i = 0; i < 10; i++) {
                pid_t r = waitpid(pid, &status, WNOHANG);
                if (r == pid || (r < 0 && errno == ECHILD)) { reaped = YES; break; }
                usleep(30 * 1000);
            }
        }
        if (!reaped) {
            // Last resort. We are the parent, so the shell is reaped later by
            // the system; nothing else we can do from here.
            kill(pid, SIGKILL);
        }
    }
}

#pragma mark Window size

- (void)applyWindowSizeCols:(int)cols rows:(int)rows
{
    // Remember the size even before the shell exists, so startShell can apply
    // it to the pty straight away instead of falling back to 80x24.
    _pendingCols = cols;
    _pendingRows = rows;

    if (_masterFD < 0) return;
    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_row = (unsigned short)rows;
    ws.ws_col = (unsigned short)cols;
    ioctl(_masterFD, TIOCSWINSZ, &ws);

    if (_childPid > 0) {
        // SIGWINCH makes the shell redraw at the new size.
        kill(_childPid, SIGWINCH);
    }
}

#pragma mark Input

- (void)writeBytes:(const uint8_t *)bytes length:(NSUInteger)length
{
    if (_masterFD < 0 || !bytes || length == 0) return;
    size_t total = (size_t)length;
    size_t written = 0;
    while (written < total) {
        ssize_t n = write(_masterFD, bytes + written, total - written);
        if (n <= 0) {
            if (errno == EAGAIN || errno == EINTR) {
                usleep(2 * 1000);
                continue;
            }
            break;
        }
        written += (size_t)n;
    }
}

- (void)textViewDidChange:(UITextView *)textView
{
    NSString *text = textView.text ?: @"";
    if (text.length == 0) return;

    // Newlines come in as '\n'; the pty expects CR for the Enter key.
    NSMutableString *send = [NSMutableString stringWithCapacity:text.length];
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c == '\n') [send appendString:@"\r"];
        else [send appendFormat:@"%C", c];
    }

    NSData *data = [send dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length > 0) {
        [self writeBytes:(const uint8_t *)data.bytes length:data.length];
    }
    // Keep the proxy empty so it never grows and never shows up in the UI.
    textView.text = @"";
}

@end
