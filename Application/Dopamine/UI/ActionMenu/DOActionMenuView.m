//
//  DOActionMenuView.m
//  Dopamine
//
//  Created by tomt000 on 04/01/2024.
//

#import "DOActionMenuView.h"
#import "DOActionMenuButton.h"
#import "DOGlobalAppearance.h"
#import "DOThemeManager.h"

@implementation DOActionMenuView

- (instancetype)initWithActions:(NSArray<UIAction*> *)actions delegate:(id<DOActionMenuDelegate>)delegate
{
    if (self = [super init])
    {
        [self setDelegate:delegate];
        [self setActions:actions];
        self.backgroundColor = [DOThemeManager menuColorWithAlpha:1.0];
        self.layer.cornerRadius = 14;
        self.layer.masksToBounds = YES;
        self.layer.cornerCurve = kCACornerCurveContinuous;
    }
    return self;
}

- (void)setActions:(NSArray *)actions
{
    _actions = actions;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self refreshStack];
    });
}

-(void)refreshStack
{
    [self.buttonsView removeFromSuperview];
    self.buttonsView = [[UIStackView alloc] init];
    self.buttonsView.axis = UILayoutConstraintAxisVertical;
    self.buttonsView.translatesAutoresizingMaskIntoConstraints = NO;

    int button_height = [DOGlobalAppearance isHomeButtonDevice] ? UI_ACTION_HEIGHT_HOME_BTN : UI_ACTION_HEIGHT;
    if ([DOGlobalAppearance isSmallDevice])
        button_height = UI_ACTION_HEIGHT_TINY;

    [self.actions enumerateObjectsUsingBlock:^(UIAction *action, NSUInteger idx, BOOL *stop) {
        DOActionMenuButton *button = [DOActionMenuButton buttonWithAction:action chevron:[self.delegate actionMenuShowsChevronForAction:action]];
        button.enabled = [self.delegate actionMenuActionIsEnabled:action];
        [button setBottomSeparator:idx != self.actions.count - 1];
        [self.buttonsView addArrangedSubview:button];
        [NSLayoutConstraint activateConstraints:@[
            [button.heightAnchor constraintEqualToConstant:button_height],
            [button.widthAnchor constraintEqualToAnchor:self.buttonsView.widthAnchor]
        ]];
    }];

    [self addSubview:self.buttonsView];

    int inner_padding = [DOGlobalAppearance isSmallDevice] ? UI_INNER_PADDING_TINY : UI_INNER_PADDING;

    [NSLayoutConstraint activateConstraints:@[
        [self.buttonsView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:inner_padding],
        [self.buttonsView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-inner_padding],
        [self.buttonsView.topAnchor constraintEqualToAnchor:self.topAnchor constant:UI_INNER_TOP_PADDING],
        [self.buttonsView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-UI_INNER_TOP_PADDING],
    ]];

}

/**
 * Re-asks the delegate which rows are enabled, without rebuilding the view.
 *
 * The enabled state was only ever computed inside `refreshStack`, which runs once when the menu is
 * created. Since this view is built in `viewDidLoad` and then lives for the whole session, the
 * delegate was consulted exactly once: after a successful jailbreak the "Restart SpringBoard",
 * "Restart Userspace" and "Terminal" rows stayed greyed out until the app was relaunched. Rebuilding
 * the stack to fix that would also restart its layout animation, so the states are refreshed in
 * place instead.
 */
- (void)refreshEnabledStates
{
    NSArray<DOActionMenuButton *> *buttons = self.buttonsView.arrangedSubviews;
    [self.actions enumerateObjectsUsingBlock:^(UIAction *action, NSUInteger idx, BOOL *stop) {
        if (idx >= buttons.count) return;
        DOActionMenuButton *button = buttons[idx];
        button.enabled = [self.delegate actionMenuActionIsEnabled:action];
    }];
}

- (void)hide
{
    [self setUserInteractionEnabled:NO];
    CGAffineTransform transform = CGAffineTransformMakeTranslation(0, -75);
    transform = CGAffineTransformScale(transform, 0.6, 0.6);
    [UIView animateWithDuration:0.3 delay:0.0 usingSpringWithDamping:0.9 initialSpringVelocity:2.0  options: UIViewAnimationOptionCurveEaseInOut animations:^{
        [self setAlpha:0.0];
        [self setTransform:transform];
    } completion:nil];
}

@end
