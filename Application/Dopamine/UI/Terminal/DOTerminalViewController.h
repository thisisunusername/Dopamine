//
//  DOTerminalViewController.h
//  Dopamine
//
//  A minimal on-device terminal that runs zsh (from the Procursus
//  bootstrap) inside a pseudo terminal, as root, once the device
//  has been jailbroken.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface DOTerminalViewController : UIViewController

// YES when a jailbroken environment is present and /var/jb/bin/zsh can be
// located. Menu entries use this to decide whether to grey themselves out.
+ (BOOL)isAvailable;

@end

NS_ASSUME_NONNULL_END
