//
//  FTLocationManager.m
//
//  Created by Lukas Kukacka on 7/31/13.
//  Copyright (c) 2013 Fuerte Int. All rights reserved.
//
//  Singleton manager for simple block-based asynchronous retrieving of actual users location
//
//
//  The MIT License (MIT)
//
//  Copyright (c) 2013 Fuerte Int. All rights reserved.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.


#import "FTLocationManager.h"

NSString *const FTLocationManagerErrorDomain = @"FTLocationManagerErrorDomain";

//  Private interface encapsulating functionality
@interface FTLocationManager () <CLLocationManagerDelegate>

@property (nonatomic, strong) CLLocationManager *locationManager;
@property (nonatomic, copy) FTLocationManagerCompletionHandler completionBlock;

@end


@implementation FTLocationManager {
    
    BOOL        _timeoutInProgress;
    NSUInteger  _errorsCount;
}

#pragma mark Lifecycle

+ (FTLocationManager *)sharedManager
{
    static FTLocationManager *SharedInstance = nil;
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        SharedInstance = [[FTLocationManager alloc] init];
    });
    
    return SharedInstance;
}

- (id)init
{
    self = [super init];
    if (self) {
        
        //  Private variables
        _errorsCount = 0;
        
        //  Default properties values
        _location = nil;
        _maxErrorsCount = 3;
        _errorTimeout = 3.0;
    }
    return self;
}

- (void)dealloc
{
    //  Dealloc should not be called on singleton instance,
    //  but for sure
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
}

#pragma mark - Accessors

- (void)setErrorTimeout:(NSTimeInterval)errorTimeout
{
    [self willChangeValueForKey:@"errorTimeout"];
    _errorTimeout = (errorTimeout >= 0.1 ? errorTimeout : 0.1);
    [self didChangeValueForKey:@"errorTimeout"];
}

#pragma mark Private

- (CLLocationManager *)locationManager
{
    //  Location manager is lazily intialized when its really needed
    if(!_locationManager)
    {
        _locationManager = [[CLLocationManager alloc] init];
        _locationManager.delegate = self;
        
        if (_desiredAccuracy > 0.0) {
            _locationManager.desiredAccuracy = _desiredAccuracy;
        }
        
        if (_distanceFilter > 0.0) {
            _locationManager.distanceFilter = _distanceFilter;
        }
    }
    
    return _locationManager;
}

#pragma mark - Public interface

- (void)updateLocationWithCompletionHandler:(FTLocationManagerCompletionHandler)completion
{
    NSAssert(completion, @"You have to provide non-NULL completion handler to [FTLocationManager updateLocationWithCompletionHandler:]");
    
    self.completionBlock = completion;
    
    //  Start new errors counting
    _errorsCount = 0;
    
    [self.locationManager startUpdatingLocation];
}

- (CLLocationDistance)distanceFromLocation:(CLLocation *)location
{
    CLLocationDistance distance = -1;
    if (self.location && CLLocationCoordinate2DIsValid(self.location.coordinate)) {
        distance = [self.location distanceFromLocation:location];
    }
    
    return distance;
}

- (NSString *)formatDistance:(CLLocationDistance)distance
{
    static NSNumberFormatter *formatter = nil;
    if (!formatter) {
        formatter = [NSNumberFormatter new];
        [formatter setLocale:[NSLocale currentLocale]];
        [formatter setNumberStyle:NSNumberFormatterDecimalStyle];
        [formatter setMaximumSignificantDigits:2];
        [formatter setUsesSignificantDigits:YES];
    }
    
    NSString *distanceString, *unitString;
    double meterDistance = distance;
    double kilometerDistance = distance * 0.001;
    
    if (kilometerDistance >= 1) {
        distanceString = [formatter stringFromNumber:@(kilometerDistance)];
        unitString = @"km";
        
    } else {
        distanceString = [formatter stringFromNumber:@(meterDistance)];
        unitString = @"m";
    }
    
    return [NSString stringWithFormat:@"%@%@", distanceString, unitString];
}

#pragma mark - Location manager delegate

- (void)locationManager:(CLLocationManager *)manager didUpdateToLocation:(CLLocation *)newLocation fromLocation:(CLLocation *)oldLocation
{
    //  We accept only CLLocation with valid locationCoordinate
    _location = (CLLocationCoordinate2DIsValid(newLocation.coordinate) ? newLocation : nil);
    
    //  Turn off the location manager to preserve energy
    [manager stopUpdatingLocation];
    
    _errorsCount = 0;
    
    //  Stop previous error timeout
    [self stopErrorTimeout];
    
    //  Call location changed callback block
    if (_completionBlock) {
        _completionBlock(_location, nil, NO);
        self.completionBlock = nil;
    }
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error
{
    _location = nil;
    
    //  Location services disabled, call the error block immediatelly
    //  ignore all errors counts and timeouts because they make no sense
    //  in this case
    if(error.domain == kCLErrorDomain && error.code == kCLErrorDenied)
    {
        _errorsCount = 0;
        [self locationUpdatingFailedWithError:error locationServicesDisabled:YES];
        return;
    }
    
    _errorsCount++;
    
    //  Start timeout of location failure
    [self startErrorTimeout];
    
    //  Number of errors in row without success exceeded reached threshold
    if(_errorsCount >= _maxErrorsCount)
    {
        [self locationUpdatingFailedWithError:error locationServicesDisabled:NO];
    }
}

#pragma mark - Private helper methods

- (void)locationUpdatingFailedWithError:(NSError *)error locationServicesDisabled:(BOOL)locationServicesDisabled
{
    [self.locationManager stopUpdatingLocation];

    //  Cancel previous error timeouts
    [self stopErrorTimeout];
    
    //  Report error with block
    if (_completionBlock) {
        _completionBlock(nil, error, locationServicesDisabled);
    }
    
    //  Reset errors count
    _errorsCount = 0;
}

- (void)locationUpdatingTimedOut
{
    //  Create custom error
    NSDictionary *userInfo = @{
       NSLocalizedDescriptionKey: NSLocalizedString(@"Failed to get current location.", @"FTLocationManager - Localized description of the error sent if the location request times out"),
       NSLocalizedFailureReasonErrorKey: NSLocalizedString(@"Request on getting a current location timed out.", @"FTLocationManager - Localized failure reason of the error sent if the location request times out")
    };
    
    NSError *error = [NSError errorWithDomain:FTLocationManagerErrorDomain code:FTLocationManagerErrorCodeTimedOut userInfo:userInfo];
    
    [self locationUpdatingFailedWithError:error locationServicesDisabled:NO];
}

- (void)startErrorTimeout
{
    //  Start timeout if the timeout is not already in progress
    if (!_timeoutInProgress)
    {
        [self performSelector:@selector(locationUpdatingTimedOut) withObject:nil afterDelay:_errorTimeout];
        _timeoutInProgress = YES;
    }
}

- (void)stopErrorTimeout
{
    //  Cancel previous "performSelector" requests
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(locationUpdatingTimedOut) object:nil];
    _timeoutInProgress = NO;
}

@end
