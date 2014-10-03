var http = require("http");
var https = require("https");
var url = require("url");
var fs = require("fs");
var path = require("path");
var util = require("util");



//var genx = require('genx'); // tried genx for generating the xml, but it was 4x slower than direct output



console.log("Fake API for testing \n");

var delay = 0;


// regexp is the regular expression to match the url path.
// fun is the callback invoked to handle such url.
// fun signature is  (request, response, arg1, arg2, ..argn) where arg1,..argn are 
// the captured strings from the regexp, if any.  (like in user_roster)
var handlers = [
	{regexp : new RegExp("^/api/auth$"), fun : auth},
	{regexp : new RegExp("^/api/user$"), fun : user},
	];


function onRequest(request, response) {
	var info = url.parse(request.url, true);
	var splitted_path = info.pathname.split("/");
	for(var i in handlers) {
		var h  = handlers[i];
		var result = h.regexp.exec(info.pathname);
		if (result != null) {
			result = result.slice(1, result.length);
			var params = [request, response].concat(result);
			h.fun.apply(h.fun, params);
		    	return;
		}
	}
	console.log("Invalid request path: " + info.pathname);
	response.writeHead(404, {"Content-Type": "text/plain"});
	response.write("404 Not found");
	response.end();
}


function auth(request, response) {
  parts = url.parse(request.url, true);
  query = parts.query;
  console.log("Authenticating user " + query.jid + " with pass " + query.password);

  request.on('data', function(data) {
  });
  request.on('end', function() {
      response.writeHead(200, {"Content-Type": "application/json"});
      response.write(JSON.stringify({}));
      response.end();
  });
}
function user(request, response) {
  request.on('data', function(data) {
  });
  request.on('end', function() {
      response.writeHead(200, {"Content-Type": "application/json"});
      response.write(JSON.stringify({}));
      response.end();
  });
}


var options = {
  key: fs.readFileSync('privatekey.pem'),
  cert: fs.readFileSync('certificate.pem')
};

https.createServer(options, onRequest).listen(443);

console.log("Available API endpoints:");
for(var i in handlers) {
	var h  = handlers[i];
	console.log(h.regexp.source);
}



