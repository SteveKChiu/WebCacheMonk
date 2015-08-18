//
// https://github.com/SteveKChiu/WebCacheMonk
//
// Copyright 2015, Steve K. Chiu <steve.k.chiu@gmail.com>
//
// The MIT License (http://www.opensource.org/licenses/mit-license.php)
//
// Permission is hereby granted, free of charge, to any person obtaining a
// copy of this software and associated documentation files (the "Software"),
// to deal in the Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, sublicense,
// and/or sell copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
// THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
// DEALINGS IN THE SOFTWARE.
//

import Foundation

//---------------------------------------------------------------------------

public enum WebCacheExpiration {
    case Never
    case Default
    case Time(NSTimeInterval)
    
    public static func Seconds(seconds: Double) -> WebCacheExpiration {
        return .Time(NSDate.timeIntervalSinceReferenceDate() + seconds)
    }
    
    public static func Minutes(minutes: Double) -> WebCacheExpiration {
        return .Time(NSDate.timeIntervalSinceReferenceDate() + minutes * 60)
    }
    
    public static func Hours(hours: Double) -> WebCacheExpiration {
        return .Time(NSDate.timeIntervalSinceReferenceDate() + hours * (60 * 60))
    }
    
    public static func Days(days: Double) -> WebCacheExpiration {
        return .Time(NSDate.timeIntervalSinceReferenceDate() + days * (24 * 60 * 60))
    }
    
    public static func Date(date: NSDate) -> WebCacheExpiration {
        return .Time(date.timeIntervalSinceReferenceDate)
    }
    
    public static func Description(string: String?) -> WebCacheExpiration {
        if let string = string {
            switch string {
            case "never":
                return .Never
            case "default":
                return .Default
            default:
                if let date = WebCacheExpiration.timeFormat.dateFromString(string) {
                    return .Date(date)
                }
            }
        }
        return .Default
    }
    
    public var description: String? {
        switch self {
        case .Never:
            return "never"
        case .Default:
            return "default"
        case let .Time(timeInterval):
            return WebCacheExpiration.timeFormat.stringFromDate(NSDate(timeIntervalSinceReferenceDate: timeInterval))
        }
    }
    
    public var isExpired: Bool {
        switch self {
        case let .Time(time):
            return time < NSDate.timeIntervalSinceReferenceDate()
        default:
            return false
        }
    }

    private static var timeFormat: NSDateFormatter = {
        let fmt = NSDateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        return fmt
    }()
}

//---------------------------------------------------------------------------

public func == (lhs: WebCacheExpiration, rhs: WebCacheExpiration) -> Bool {
    switch (lhs, rhs) {
    case (.Default, .Default):      return true
    case (.Never, .Never):          return true
    case let (.Time(a), .Time(b)):  return a == b
    default:                        return false
    }
}

public func != (lhs: WebCacheExpiration, rhs: WebCacheExpiration) -> Bool {
    return !(lhs == rhs)
}
