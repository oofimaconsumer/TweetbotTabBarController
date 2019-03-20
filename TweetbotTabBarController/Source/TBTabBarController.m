//
//  TBTabBarController.m
//  TBTabBarController
//
//  Created by Timur Ganiev on 03/02/2019.
//  Copyright © 2019 Timur Ganiev. All rights reserved.
//

#import "TBTabBarController.h"

#import "TBFakeNavigationBar.h"

#import "TBTabBar+Private.h"
#import "_TBTabBarButton.h"
#import "_TBDotView.h"

#import <objc/runtime.h>

typedef NS_OPTIONS(NSUInteger, TBTabBarControllerMethodOverrides) {
    TBTabBarControllerMethodOverrideNone = 0,
    TBTabBarControllerMethodOverridePreferredTabBarPositionForHorizontalSizeClass = 1 << 0,
    TBTabBarControllerMethodOverridePreferredTabBarPositionForViewSize = 1 << 1
};

@interface TBTabBarController ()

@property (strong, nonatomic, readwrite) TBTabBar *leftTabBar;
@property (strong, nonatomic, readwrite) TBTabBar *bottomTabBar;
@property (weak, nonatomic, readwrite) TBTabBar *visibleTabBar;
@property (weak, nonatomic, readwrite) TBTabBar *hiddenTabBar;

@property (strong, nonatomic) UIStackView *containerView; // contains the fake nav bar and the left tab bar

@property (strong, nonatomic) TBFakeNavigationBar *fakeNavigationBar;

@property (strong, nonatomic) NSArray <TBTabBarItem *> *items; // since we are not operating with only one tab bar, we have to keep all the items here

@property (weak, nonatomic) UINavigationController *childNavigationController;

@property (strong, nonatomic) NSLayoutConstraint *bottomTabBarBottomConstraint;
@property (strong, nonatomic) NSLayoutConstraint *bottomTabBarHeightConstraint;

@property (strong, nonatomic) NSLayoutConstraint *containerViewWidthConstraint;
@property (strong, nonatomic) NSLayoutConstraint *containerViewLeftConstraint;
@property (strong, nonatomic) NSLayoutConstraint *containerViewBottomConstraint;

@property (strong, nonatomic) NSLayoutConstraint *fakeNavBarHeightConstraint;

@end

static TBTabBarControllerMethodOverrides tb_methodOverridesFlags;

@implementation TBTabBarController {
    
    // Position flags
    TBTabBarControllerTabBarPosition tb_currentPosition;
    TBTabBarControllerTabBarPosition tb_preferredPosition;
}

static void *tb_tabBarItemImageContext = &tb_tabBarItemImageContext;
static void *tb_tabBarItemSelectedImageContext = &tb_tabBarItemSelectedImageContext;
static void *tb_tabBarItemEnabledContext = &tb_tabBarItemEnabledContext;
static void *tb_tabBarItemShowDotContext = &tb_tabBarItemShowDotContext;

#pragma mark - Public

- (instancetype)init {
    
    self = [super init];
    
    if (self) {
        [self tb_commonInit];
    }
    
    return self;
}


- (instancetype)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil {
    
    self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
    
    if (self) {
        [self tb_commonInit];
    }
    
    return self;
}


#pragma mark Lifecycle

+ (void)initialize {
    
    [super initialize];
    
    if (self != [TBTabBarController class]) {
        
        if ([self tb_doesSubclassOverrideMethod:@selector(preferredTabBarPositionForHorizontalSizeClass:)]) {
            tb_methodOverridesFlags |= TBTabBarControllerMethodOverridePreferredTabBarPositionForHorizontalSizeClass;
        }
        if ([self tb_doesSubclassOverrideMethod:@selector(preferredTabBarPositionForViewSize:)]) {
            tb_methodOverridesFlags |= TBTabBarControllerMethodOverridePreferredTabBarPositionForViewSize;
        }
        NSAssert(tb_methodOverridesFlags <= TBTabBarControllerMethodOverridePreferredTabBarPositionForViewSize, @"The %@ subclass overrides both methods of the Subclasses category.", NSStringFromClass(self));
    }
}


- (void)dealloc {
    
    [self tb_stopObservingTabBarItems];
}


#pragma mark View lifecycle

- (void)viewDidLoad {
    
    [super viewDidLoad];
    
    [self tb_setup];
}


#pragma mark Status bar

- (UIStatusBarStyle)preferredStatusBarStyle {
    
    return [self tb_getCurrentlyVisibleViewController].preferredStatusBarStyle;
}


- (BOOL)prefersStatusBarHidden {
    
    return [self tb_getCurrentlyVisibleViewController].prefersStatusBarHidden;
}


- (UIStatusBarAnimation)preferredStatusBarUpdateAnimation {
    
    return [self tb_getCurrentlyVisibleViewController].preferredStatusBarUpdateAnimation;
}


#pragma mark UIViewControllerRotation

- (BOOL)shouldAutorotate {
    
    return [self tb_getCurrentlyVisibleViewController].shouldAutorotate;
}


- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    
    return [self tb_getCurrentlyVisibleViewController].supportedInterfaceOrientations;
}


#pragma mark UIConstraintBasedLayoutCoreMethods

- (void)updateViewConstraints {
    
    [super updateViewConstraints];
    
    if (tb_preferredPosition != TBTabBarControllerTabBarPositionUnspecified) {
        [self tb_updateViewConstraints];
        [self tb_updateFakeNavigationBarHeightConstraint];
        tb_preferredPosition = TBTabBarControllerTabBarPositionUnspecified; // An unspecified position means that the trait collection has not been changed, so we have to rely on the current one
    }
}


#pragma mark Subclasses

- (TBTabBarControllerTabBarPosition)preferredTabBarPositionForHorizontalSizeClass:(UIUserInterfaceSizeClass)sizeClass {
    
    return [self tb_preferredTabBarPositionForHorizontalSizeClass:sizeClass];
}


- (TBTabBarControllerTabBarPosition)preferredTabBarPositionForViewSize:(CGSize)size {
    
    return tb_preferredPosition;
}


#pragma mark UIContentContainer

- (void)willTransitionToTraitCollection:(UITraitCollection *)newCollection withTransitionCoordinator:(id <UIViewControllerTransitionCoordinator>)coordinator {
    
    UIUserInterfaceSizeClass const newHorizontalSizeClass = newCollection.horizontalSizeClass;
    
    if (self.traitCollection.horizontalSizeClass != newHorizontalSizeClass) {
        
        if ((tb_methodOverridesFlags & TBTabBarControllerMethodOverridePreferredTabBarPositionForViewSize) == false) {
            tb_preferredPosition = [self preferredTabBarPositionForHorizontalSizeClass:newHorizontalSizeClass];
            [self tb_specifyPreferredPositionWithHorizontalSizeClassIfNecessary:newHorizontalSizeClass]; // Subclasses may return an unspecified position
        } else {
            // In case where a subclass overrides the -preferredTabBarPositionForViewSize: method, we should capture new preferred position for a new horizontal size class since a subclass may return either an unspecified position or call super.
            tb_preferredPosition = [self tb_preferredTabBarPositionForHorizontalSizeClass:newHorizontalSizeClass];
        }
    }
    
    [super willTransitionToTraitCollection:newCollection withTransitionCoordinator:coordinator];
}


- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id <UIViewControllerTransitionCoordinator>)coordinator {
    
    // The horizontal size class doesn't change every time.
    // When the user rotates an iPad the view has the same horizontal size class, but its size will be changed.
    // The same happens when the user switches between 2/3 and 1/2 split view modes.
    // Subclasses can rely on this change and show the tab bar on the other side.
    
    if (tb_methodOverridesFlags & TBTabBarControllerMethodOverridePreferredTabBarPositionForViewSize) {
        
        // By default the preferredTabBarPositionForViewSize: method returns tb_preferredPosition property, so we have to capture it before a subclass will call super
        // An unspecified position means that trait collection has not been changed in a while
        [self tb_specifyPreferredPositionWithHorizontalSizeClassIfNecessary:self.traitCollection.horizontalSizeClass];
        
        TBTabBarControllerTabBarPosition preferredPosition = [self preferredTabBarPositionForViewSize:size];
        
        if (preferredPosition == TBTabBarControllerTabBarPositionUnspecified) {
            // Subclasses may return an unspecified position
            preferredPosition = tb_preferredPosition;
        } else if (preferredPosition != tb_preferredPosition) {
            // Capturing a new preferred position for the layout cycle
            tb_preferredPosition = preferredPosition;
        }
    }
    
    [self tb_updateTabBarsVisibilityWithTransitionCoordinator:coordinator];
    
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
}


#pragma mark UITraitEnvironment

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    
    if (previousTraitCollection == nil) {
        UIUserInterfaceSizeClass const horizontalSizeClass = self.traitCollection.horizontalSizeClass;
        // Capture preferred position for subclasses
        tb_preferredPosition = [self tb_preferredTabBarPositionForHorizontalSizeClass:horizontalSizeClass];
        // Capture preferred position
        if (tb_methodOverridesFlags & TBTabBarControllerMethodOverridePreferredTabBarPositionForViewSize) {
            tb_preferredPosition = [self preferredTabBarPositionForViewSize:self.view.frame.size];
        } else {
            tb_preferredPosition = [self preferredTabBarPositionForHorizontalSizeClass:horizontalSizeClass];
        }
        [self tb_specifyPreferredPositionWithHorizontalSizeClassIfNecessary:horizontalSizeClass];
        // Capture current position
        tb_currentPosition = tb_preferredPosition;
        // Update tab bars visibility
        TBTabBar *tabBarToShow, *tabBarToHide;
        [self tb_getCurrentlyVisibleTabBar:&tabBarToShow andHiddenTabBar:&tabBarToHide];
        [self tb_makeTabBarVisible:tabBarToShow];
        [self tb_makeTabBarHidden:tabBarToHide];
        // Update constraints
        [self.view setNeedsUpdateConstraints];
        [self.view updateConstraintsIfNeeded];
        // Make the vertical tab bar look good
        [self tb_updateVerticalTabBarBottomContentInsetWithNewValue:self.leftTabBar.contentInsets.bottom andItsBottomConstraintWithNewConstant:-(_bottomTabBarHeightConstraint.constant)];
    }
    
    [super traitCollectionDidChange:previousTraitCollection];
}


#pragma mark KVO

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary <NSKeyValueChangeKey, id> *)change context:(void *)context {
    
    NSUInteger const itemIndex = [self.visibleTabBar.items indexOfObject:object];
    
    if (itemIndex == NSNotFound) {
        return;
    }
    
    _TBTabBarButton *bottomTabBarButtonAtIndex = self.bottomTabBar.buttons[itemIndex];
    _TBTabBarButton *leftTabBarButtonAtIndex = self.leftTabBar.buttons[itemIndex];
    
    if (context == tb_tabBarItemImageContext) {
        UIImage *newImage = (UIImage *)change[NSKeyValueChangeNewKey];
        [bottomTabBarButtonAtIndex setImage:newImage forState:UIControlStateNormal];
        [leftTabBarButtonAtIndex setImage:newImage forState:UIControlStateNormal];
    } else if (context == tb_tabBarItemSelectedImageContext) {
        UIImage *newSelectedImage = (UIImage *)change[NSKeyValueChangeNewKey];
        [bottomTabBarButtonAtIndex setImage:newSelectedImage forState:UIControlStateSelected];
        [leftTabBarButtonAtIndex setImage:newSelectedImage forState:UIControlStateSelected];
    } else if (context == tb_tabBarItemEnabledContext) {
        BOOL const enabled = [(NSNumber *)change[NSKeyValueChangeNewKey] boolValue];
        bottomTabBarButtonAtIndex.enabled = enabled;
        leftTabBarButtonAtIndex.enabled = enabled;
    } else if (context == tb_tabBarItemShowDotContext) {
        BOOL const showDot = ![(NSNumber *)change[NSKeyValueChangeNewKey] boolValue];
        bottomTabBarButtonAtIndex.dotView.hidden = showDot;
        leftTabBarButtonAtIndex.dotView.hidden = showDot;
    }
}


#pragma mark TBTabBarDelegate

- (void)tabBar:(TBTabBar *)tabBar didSelectItem:(TBTabBarItem *)item {
    
    NSUInteger const itemIndex = [_items indexOfObject:item];
    
    BOOL shouldSelectViewController = (itemIndex == self.selectedIndex) ? false : true;
    
    __kindof UIViewController *childViewController = self.viewControllers[itemIndex];
    
    id <TBTabBarControllerDelegate> delegate = self.delegate;
    
    if ([delegate respondsToSelector:@selector(tabBarController:shouldSelectViewController:)]) {
        shouldSelectViewController = [delegate tabBarController:self shouldSelectViewController:childViewController];
    }
    
    if (shouldSelectViewController == false) {
        return;
    }
    
    self.selectedIndex = itemIndex;
    
    if ([delegate respondsToSelector:@selector(tabBarController:didSelectViewController:)]) {
        [delegate tabBarController:self didSelectViewController:childViewController];
    }
}


#pragma mark - Private

- (void)tb_commonInit {
    
    // UINavigationBar
    [UINavigationBar appearanceWhenContainedInInstancesOfClasses:@[[self class]]].translucent = false;
    
    // Public
    self.startingIndex = 0;
    self.horizontalTabBarHeight = 49.0;
    self.verticalTabBarWidth = 60.0;
}


- (void)tb_setup {
    
    self.view.backgroundColor = [UIColor whiteColor];
    
    // Horizontal tab bar
    [self.view addSubview:self.bottomTabBar];
    
    // Container view
    _containerView = [[UIStackView alloc] initWithFrame:CGRectZero];
    _containerView.axis = UILayoutConstraintAxisVertical;
    _containerView.alignment = UIStackViewAlignmentCenter;
    _containerView.distribution = UIStackViewDistributionFill;
    _containerView.spacing = 0.0;
    _containerView.translatesAutoresizingMaskIntoConstraints = false;
    
    [self.view addSubview:_containerView];
    
    // Verical tab bar
    [_containerView addArrangedSubview:self.fakeNavigationBar];
    [_containerView addArrangedSubview:self.leftTabBar];
    
    // Constraints
    [self tb_setupConstraints];
}


#pragma mark Layout

- (void)tb_setupConstraints {
    
    UIView *view = self.view;
    
    UIStackView *containerView = self.containerView;
    
    TBTabBar *bottomTabBar = self.bottomTabBar;
    
    // Container view
    _containerViewLeftConstraint = [containerView.leftAnchor constraintEqualToAnchor:view.leftAnchor];
    NSLayoutConstraint *containerViewTopConstraint = [containerView.topAnchor constraintEqualToAnchor:view.topAnchor];
    _containerViewBottomConstraint = [containerView.bottomAnchor constraintEqualToAnchor:bottomTabBar.bottomAnchor];
    _containerViewWidthConstraint = [containerView.widthAnchor constraintEqualToConstant:self.verticalTabBarWidth];
    
    TBFakeNavigationBar *fakeNavBar = self.fakeNavigationBar;
    
    // Fake navigation bar
    NSLayoutConstraint *fakeNavBarWidthConstraint = [fakeNavBar.widthAnchor constraintEqualToAnchor:containerView.widthAnchor];
    _fakeNavBarHeightConstraint = [fakeNavBar.heightAnchor constraintEqualToConstant:40.0];
    
    TBTabBar *leftTabBar = self.leftTabBar;
    
    // Left tab bar
    NSLayoutConstraint *leftTabBarWidthConstraint = [leftTabBar.widthAnchor constraintEqualToAnchor:self.containerView.widthAnchor];
    
    // Bottom tab bar
    NSLayoutConstraint *bottomTabBarLeftConstraint = [bottomTabBar.leftAnchor constraintEqualToAnchor:containerView.rightAnchor];
    NSLayoutConstraint *bottomTabBarRightConstraint = [bottomTabBar.rightAnchor constraintEqualToAnchor:view.rightAnchor];
    _bottomTabBarBottomConstraint = [bottomTabBar.bottomAnchor constraintEqualToAnchor:view.bottomAnchor];
    _bottomTabBarHeightConstraint = [bottomTabBar.heightAnchor constraintEqualToConstant:self.horizontalTabBarHeight];
    
    // Activation
    [NSLayoutConstraint activateConstraints:@[_containerViewLeftConstraint, containerViewTopConstraint, _containerViewBottomConstraint, _containerViewWidthConstraint, fakeNavBarWidthConstraint, _fakeNavBarHeightConstraint, leftTabBarWidthConstraint, bottomTabBarLeftConstraint, bottomTabBarRightConstraint, _bottomTabBarBottomConstraint, _bottomTabBarHeightConstraint]];
}


- (void)tb_updateViewConstraints {
    
    UIEdgeInsets safeAreaInsets = self.view.safeAreaInsets;
    UIEdgeInsets bottomTabBarContentInsets = self.bottomTabBar.contentInsets;
    UIEdgeInsets leftTabBarContentInsets = self.leftTabBar.contentInsets;
    
    CGFloat const minBottomTabBarHeight = self.horizontalTabBarHeight + safeAreaInsets.bottom;
    CGFloat const minLeftTabBarWidth = self.verticalTabBarWidth + safeAreaInsets.left;
    CGFloat const bottomTabBarHeight = MAX(minBottomTabBarHeight + bottomTabBarContentInsets.top + bottomTabBarContentInsets.bottom, minBottomTabBarHeight);
    CGFloat const leftTabBarWidth = MAX(minLeftTabBarWidth + leftTabBarContentInsets.left + leftTabBarContentInsets.right, minLeftTabBarWidth);
    
    _bottomTabBarHeightConstraint.constant = bottomTabBarHeight;
    _containerViewWidthConstraint.constant = leftTabBarWidth;
    
    if (tb_preferredPosition == TBTabBarControllerTabBarPositionLeft) {
        _bottomTabBarBottomConstraint.constant = bottomTabBarHeight;
        _containerViewLeftConstraint.constant = 0.0;
    } else {
        _bottomTabBarBottomConstraint.constant = 0.0;
        _containerViewLeftConstraint.constant = -leftTabBarWidth;
    }
}


- (void)tb_updateFakeNavigationBarHeightConstraint {
    
    _fakeNavBarHeightConstraint.constant = CGRectGetMaxY(_childNavigationController.navigationBar.frame) + (1.0 / self.traitCollection.displayScale);
}


- (void)tb_updateVerticalTabBarBottomContentInsetWithNewValue:(CGFloat)value andItsBottomConstraintWithNewConstant:(CGFloat)constant {
    
    TBTabBar *tabBar = self.leftTabBar;
    
    UIEdgeInsets contentInsets = tabBar.contentInsets;
    contentInsets.bottom = value;
    
    tabBar.contentInsets = contentInsets;
    
    _containerViewBottomConstraint.constant = constant;
}


- (void)tb_updateTabBarsVisibilityWithTransitionCoordinator:(id <UIViewControllerTransitionCoordinator>)coordinator {
    
    if (tb_preferredPosition == TBTabBarControllerTabBarPositionUnspecified || tb_preferredPosition == tb_currentPosition) {
        return;
    }
    
    [self.view setNeedsUpdateConstraints];
    
    TBTabBar *visibleTabBar, *hiddenTabBar;
    [self tb_getCurrentlyVisibleTabBar:&visibleTabBar andHiddenTabBar:&hiddenTabBar];
    
    [self tb_makeTabBarVisible:hiddenTabBar]; // Show the currently hidden tab bar
    
    tb_currentPosition = tb_preferredPosition;
    
    CGFloat const previousVerticalTabBarBottomInset = self.leftTabBar.contentInsets.bottom;
    
    __weak typeof(self) weakSelf = self;
    
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext>  _Nonnull context) {
        [weakSelf.view updateConstraintsIfNeeded];
        [weakSelf tb_updateVerticalTabBarBottomContentInsetWithNewValue:-(weakSelf.bottomTabBarHeightConstraint.constant) andItsBottomConstraintWithNewConstant:0.0];
    } completion:^(id <UIViewControllerTransitionCoordinatorContext> context) {
        [weakSelf tb_makeTabBarHidden:visibleTabBar]; // Hide the previously visible tab bar
        [weakSelf tb_updateVerticalTabBarBottomContentInsetWithNewValue:previousVerticalTabBarBottomInset andItsBottomConstraintWithNewConstant:-weakSelf.bottomTabBarHeightConstraint.constant];
    }];
}


- (void)tb_makeTabBarVisible:(TBTabBar *)tabBar {
    
    _visibleTabBar = tabBar;
    
    if (_visibleTabBar.isVertical) {
        self.containerView.hidden = false;
        self.selectedViewController.additionalSafeAreaInsets = UIEdgeInsetsZero;
    } else {
        _visibleTabBar.hidden = false;
        self.selectedViewController.additionalSafeAreaInsets = UIEdgeInsetsMake(0.0, 0.0, self.horizontalTabBarHeight, 0.0);
    }
}


- (void)tb_makeTabBarHidden:(TBTabBar *)tabBar {
    
    _hiddenTabBar = tabBar;
    
    if (_hiddenTabBar.isVertical) {
        self.containerView.hidden = true;
    } else {
        _hiddenTabBar.hidden = true;
    }
}


#pragma mark Transitions

- (void)tb_transitionToViewControllerAtIndex:(NSUInteger)index {
    
    NSArray <__kindof UIViewController *> *const children = self.viewControllers;
    
    if (index > children.count) {
        index = children.count - 1;
    }
    
    // Show a new view controller
    [self tb_removeChildViewControllerIfExists];
    [self tb_presentChildViewController:children[index]];
    [self tb_captureChildNavigationControllerIfExsists];
    
    // Update tab bars
    self.bottomTabBar.selectedIndex = index;
    self.leftTabBar.selectedIndex = index;
    
    // Layout everything
    if (tb_preferredPosition == TBTabBarControllerTabBarPositionUnspecified) {
        tb_preferredPosition = tb_currentPosition;
    }
    
    [self.view setNeedsUpdateConstraints];
    
    [self setNeedsStatusBarAppearanceUpdate];
}


- (void)tb_presentChildViewController:(__kindof UIViewController *)viewController {
    
    _selectedViewController = viewController;
    
    [viewController willMoveToParentViewController:self];
    [self addChildViewController:viewController];
    [self.view addSubview:viewController.view];
    [viewController didMoveToParentViewController:self];
    [self.view sendSubviewToBack:viewController.view];
    
    viewController.view.translatesAutoresizingMaskIntoConstraints = false;
    
    [viewController.view.leftAnchor constraintEqualToAnchor:_containerView.rightAnchor].active = true;
    [viewController.view.rightAnchor constraintEqualToAnchor:self.view.rightAnchor].active = true;
    [viewController.view.topAnchor constraintEqualToAnchor:self.view.topAnchor].active = true;
    [viewController.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor].active = true;
}


- (void)tb_removeChildViewControllerIfExists {
    
    if (self.selectedViewController == nil) {
        return;
    }
    
    [NSLayoutConstraint deactivateConstraints:self.selectedViewController.view.constraints];
    
    [self.selectedViewController willMoveToParentViewController:nil];
    [self.selectedViewController removeFromParentViewController];
    [self.selectedViewController.view removeFromSuperview];
    [self.selectedViewController didMoveToParentViewController:nil];
    
    _selectedViewController = nil;
    _childNavigationController = nil;
}


#pragma mark Observing

- (void)tb_startObservingTabBarItems {
    
    for (TBTabBarItem *item in _items) {
        [item addObserver:self forKeyPath:@"image" options:NSKeyValueObservingOptionNew context:tb_tabBarItemImageContext];
        [item addObserver:self forKeyPath:@"selectedImage" options:NSKeyValueObservingOptionNew context:tb_tabBarItemSelectedImageContext];
        [item addObserver:self forKeyPath:@"enabled" options:NSKeyValueObservingOptionNew context:tb_tabBarItemEnabledContext];
        [item addObserver:self forKeyPath:@"showDot" options:NSKeyValueObservingOptionNew context:tb_tabBarItemShowDotContext];
    }
}

- (void)tb_stopObservingTabBarItems {
    
    for (TBTabBarItem *item in _items) {
        [item removeObserver:self forKeyPath:@"image" context:tb_tabBarItemImageContext];
        [item removeObserver:self forKeyPath:@"selectedImage" context:tb_tabBarItemSelectedImageContext];
        [item removeObserver:self forKeyPath:@"enabled" context:tb_tabBarItemEnabledContext];
        [item removeObserver:self forKeyPath:@"showDot" context:tb_tabBarItemShowDotContext];
    }
}


#pragma mark Utils

+ (BOOL)tb_doesSubclassOverrideMethod:(SEL)selector {
    
    Method superclassMethod = class_getInstanceMethod([TBTabBarController class], selector);
    Method subclassMethod = class_getInstanceMethod(self, selector);
    
    return superclassMethod != subclassMethod;
}


- (void)tb_specifyPreferredPositionWithHorizontalSizeClassIfNecessary:(UIUserInterfaceSizeClass)sizeClass {
    
    if (tb_preferredPosition == TBTabBarControllerTabBarPositionUnspecified) {
        tb_preferredPosition = [self tb_preferredTabBarPositionForHorizontalSizeClass:sizeClass];
    }
}


- (TBTabBarControllerTabBarPosition)tb_preferredTabBarPositionForHorizontalSizeClass:(UIUserInterfaceSizeClass)sizeClass  {
    
    if (sizeClass == UIUserInterfaceSizeClassRegular) {
        return TBTabBarControllerTabBarPositionLeft;
    }
    
    return TBTabBarControllerTabBarPositionBottom;
}


- (__kindof UIViewController *)tb_getCurrentlyVisibleViewController {
    
    return _childNavigationController ? _childNavigationController.visibleViewController : self.selectedViewController;
}


- (void)tb_captureChildNavigationControllerIfExsists {
    
    // This method was borrowed from TOTabBarController (https://github.com/TimOliver/TOTabBarController)
    
    UIViewController *viewController = self.selectedViewController;
    
    do {
        if ([viewController isKindOfClass:[UINavigationController class]]) {
            _childNavigationController = (UINavigationController *)viewController;
            break;
        }
    } while ((viewController = viewController.childViewControllers.firstObject));
}


- (void)tb_processChildrenOfViewControllersWithValue:(id)value {
    
    for (UIViewController *viewController in _viewControllers) {
        [self tb_processChildrenOfViewController:viewController withValue:value];
    }
}


- (void)tb_processChildrenOfViewController:(__kindof UIViewController *)viewController withValue:(id)value {
    
    for (__kindof UIViewController *childViewController in viewController.childViewControllers) {
        [self tb_processChildrenOfViewController:childViewController withValue:value];
    }
    
    [viewController setValue:value forKey:@"tb_tabBarController"];
}


- (void)tb_captureTabBarItems {
    
    self.items = [_viewControllers valueForKeyPath:@"@unionOfObjects.tb_tabBarItem"];
}


- (void)tb_getCurrentlyVisibleTabBar:(TBTabBar **)visibleTabBar andHiddenTabBar:(TBTabBar **)hiddenTabBar {
    
    switch (tb_currentPosition) {
        case TBTabBarControllerTabBarPositionBottom:
            *visibleTabBar = self.bottomTabBar;
            *hiddenTabBar = self.leftTabBar;
            break;
        case TBTabBarControllerTabBarPositionLeft:
            *visibleTabBar = self.leftTabBar;
            *hiddenTabBar = self.bottomTabBar;
            break;
        default:
            break;
    }
}


#pragma mark Getters

- (TBTabBar *)bottomTabBar {
    
    if (_bottomTabBar == nil) {
        _bottomTabBar = [[TBTabBar alloc] initWithLayoutOrientation:TBTabBarLayoutOrientationHorizontal];
        _bottomTabBar.delegate = self;
        _bottomTabBar.translatesAutoresizingMaskIntoConstraints = false;
    }
    
    return _bottomTabBar;
}


- (TBTabBar *)leftTabBar {
    
    if (_leftTabBar == nil) {
        _leftTabBar = [[TBTabBar alloc] initWithLayoutOrientation:TBTabBarLayoutOrientationVertical];
        _leftTabBar.delegate = self;
    }
    
    return _leftTabBar;
}


- (TBFakeNavigationBar *)fakeNavigationBar {
    
    if (_fakeNavigationBar == nil) {
        _fakeNavigationBar = [[TBFakeNavigationBar alloc] init];
    }
    
    return _fakeNavigationBar;
}


#pragma mark Setters

- (void)setViewControllers:(NSArray <__kindof UIViewController *> *)viewControllers {
    
    NSAssert(viewControllers.count <= 5, @"The number of view controllers must not exceed 5.");
    
    if ([viewControllers isEqual:_viewControllers]) {
        return;
    }
    
    if (_viewControllers.count > 0) {
        [self tb_stopObservingTabBarItems]; // Should we do this here?
        [self tb_processChildrenOfViewControllersWithValue:nil];
    }
    
    if (viewControllers == nil) {
        _viewControllers = viewControllers;
        return;
    }
    
    _viewControllers = [viewControllers copy];
    
    [self tb_processChildrenOfViewControllersWithValue:self];
    [self tb_captureTabBarItems];
    
    [self tb_transitionToViewControllerAtIndex:self.startingIndex];
}


- (void)setSelectedViewController:(__kindof UIViewController *)visibleViewController {
    
    NSUInteger index = [self.viewControllers indexOfObject:visibleViewController];
    
    if (index == NSNotFound) {
        return;
    }
    
    self.selectedIndex = index;
}


- (void)setSelectedIndex:(NSUInteger)selectedIndex {
    
    if (selectedIndex >= self.viewControllers.count) {
        selectedIndex = 0;
    }
    
    if (selectedIndex == _selectedIndex) {
        return;
    }
    
    _selectedIndex = selectedIndex;
    
    [self tb_transitionToViewControllerAtIndex:selectedIndex];
}


- (void)setVerticalTabBarWidth:(CGFloat)verticalTabBarWidth {
    
    _verticalTabBarWidth = verticalTabBarWidth;
    
    _containerViewWidthConstraint.constant = verticalTabBarWidth;
}


- (void)setHorizontalTabBarHeight:(CGFloat)horizontalTabBarHeight {
    
    _horizontalTabBarHeight = horizontalTabBarHeight;
    
    _bottomTabBarHeightConstraint.constant = horizontalTabBarHeight;
}


- (void)setItems:(NSArray <TBTabBarItem *> *)items {
    
    if ([items isEqual:_items]) {
        return;
    }
    
    _items = items;
    
    self.bottomTabBar.items = items;
    self.leftTabBar.items = items;
    
    [self tb_startObservingTabBarItems];
}

@end

#pragma mark -

@implementation UIViewController (TBTabBarControllerItem)

static char *tb_tabBarItemPropertyKey;
static char *tb_tabBarControllerPropertyKey;

#pragma mark - Private

#pragma mark Getters

- (TBTabBarItem *)tb_tabBarItem {
    
    TBTabBarItem *item = objc_getAssociatedObject(self, &tb_tabBarItemPropertyKey);
    
    if (item == nil) {
        item = [[TBTabBarItem alloc] init];
        objc_setAssociatedObject(self, &tb_tabBarItemPropertyKey, item, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    
    return item;
}


- (TBTabBarController *)tb_tabBarController {
    
    return objc_getAssociatedObject(self, &tb_tabBarControllerPropertyKey);
}


#pragma mark Setters

- (void)setTb_tabBarItem:(TBTabBarItem * _Nonnull)tb_tabBarItem {
    
    objc_setAssociatedObject(self, &tb_tabBarItemPropertyKey, tb_tabBarItem, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}


- (void)setTb_tabBarController:(TBTabBarController * _Nullable)tb_tabBarController {
    
    objc_setAssociatedObject(self, &tb_tabBarControllerPropertyKey, tb_tabBarController, OBJC_ASSOCIATION_ASSIGN);
}

@end
