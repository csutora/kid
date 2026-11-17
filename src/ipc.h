#pragma once

#import <Foundation/Foundation.h>

NSString *ipc_socket_path(void);
bool ipc_serve(NSString *(^handler)(NSString *request));
NSString *ipc_request(NSString *request);
