var http = require("http");
var url = require("url");
var fs = require("fs");
var path = require("path");
var util = require("util");

console.log("Fake API for testing rest offline storage \n");

var delay = 0;


// regexp is the regular expression to match the url path.
// fun is the callback invoked to handle such url.
// fun signature is  (request, response, arg1, arg2, ..argn) where arg1,..argn are
// the captured strings from the regexp, if any.  (like in user_roster)
var handlers = [
	{method:"GET", regexp : new RegExp("^/api/offline/(.*)/count$"), fun : offline_count},
	{method:"POST", regexp : new RegExp("^/api/offline/(.*)/pop$"), fun : offline_pop},
	{method:"GET", regexp : new RegExp("^/api/offline/(.*)$"), fun : offline_get},
	{method:"POST", regexp : new RegExp("^/api/offline/(.*)$"), fun : offline_store},
	{method:"DELETE", regexp : new RegExp("^/api/offline/(.*)$"), fun : offline_delete}
	];


function onRequest(request, response) {
	var info = url.parse(request.url, true);
	var splitted_path = info.pathname.split("/");
	for(var i in handlers) {
		var h  = handlers[i];
		var result = h.regexp.exec(info.pathname);
		if (result != null && request.method == h.method) {
			result = result.slice(1, result.length);
			var params = [request, response].concat(result);
			h.fun.apply(h.fun, params);
		    	return;
		}
	}
	console.log("Invalid request : " + request.method + " " + info.pathname);
	response.writeHead(404, {"Content-Type": "text/plain"});
	response.write("404 Not found");
	response.end();
}

function file_for_user(user) {
    return 'spool/'  + user + '.json'
}

function offline_count(request, response, user) {
    fs.readFile(file_for_user(user),function(err,content) {
         prev = []
         if (! err) {
             prev = JSON.parse(content);
         }
         prev.length
        response.writeHead(200, {"Content-Type": "application/json"});
        response.write(JSON.stringify({"count":prev.length}));
        response.end();
    })
}

function offline_retrieve(request, response, user, should_delete) {
    file = file_for_user(user);
    fs.readFile(file,function(err,content) {
        prev = []
        if (! err) {
            prev = JSON.parse(content);
            if (should_delete) {
                fs.unlink(file, function(err) {
                    response.writeHead(200, {"Content-Type": "application/json"});
                    response.write(JSON.stringify(prev));
                    response.end();
                });
            } else {
                response.writeHead(200, {"Content-Type": "application/json"});
                response.write(JSON.stringify(prev));
                response.end();
            }
        } else {
            response.writeHead(200, {"Content-Type": "application/json"});
            response.write(JSON.stringify(prev));
            response.end();
        }
    })
}

function offline_pop(request, response, user) {
    offline_retrieve(request, response, user, true);
}
function offline_get(request, response, user) {
    offline_retrieve(request, response, user, false);
}

function offline_delete(request, response, user) {
    file = file_for_user(user);
    fs.unlink(file, function(err) {
        response.writeHead(200, {"Content-Type": "application/json"});
        response.write(JSON.stringify({"result": "ok"}));
        response.end();
    });
}


function offline_store(request, response, user) {
    var body = '';
    request.on('data', function(data) {
        body += data;
        // Too much POST data, kill the connection!
        if (body.length > 1e6)
            request.connection.destroy();
    });
    request.on('end', function() {
        pbody = JSON.parse(body);
        console.log("Storing offline messages for " + user +
                    ": \n" + JSON.stringify(pbody));

        file = file_for_user(user);
        fs.readFile(file,function(err,content) {
                         prev = []
                         if (! err) {
                             prev = JSON.parse(content);
                         }
                         prev.push(pbody);
                         fs.writeFile(file, JSON.stringify(prev), function(err) {
                            if (err) {
                                response.writeHead(400, {"Content-Type": "application/json"});
                                response.write("Error writing to file:"  + err);
                                response.end();
                            } else {
                                response.writeHead(200, {"Content-Type": "application/json"});
                                response.write(JSON.stringify({}));
                                response.end();
                            }
                         })
        })
        });
}


// https.createServer(options, onRequest).listen(443);
http.createServer( onRequest).listen(9000);

console.log("Available API endpoints:");
for(var i in handlers) {
	var h  = handlers[i];
	console.log(h.method + "\t" + h.regexp.source);
}
