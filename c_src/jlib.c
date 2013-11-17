#include <erl_nif.h>
#include <string.h>

#define STATE_NODE 1
#define STATE_SERVER 2
#define STATE_RESOURCE 3

static int load(ErlNifEnv* env, void** priv, ERL_NIF_TERM load_info)
{
  return 0;
}

static ERL_NIF_TERM make_error(ErlNifEnv* env,
			       ErlNifBinary* input,
			       ErlNifBinary* node,
			       ErlNifBinary* server,
			       ErlNifBinary* resource)
{
  enif_release_binary(input);
  enif_release_binary(node);
  enif_release_binary(server);
  enif_release_binary(resource);
  return enif_make_atom(env, "error");
}

static ERL_NIF_TERM string_to_usr(ErlNifEnv* env, int argc,
				  const ERL_NIF_TERM argv[])
{
  int pos = 0;
  int amp = 0;
  int slash = 0;
  int state = STATE_NODE;
  char chr;
  ErlNifBinary input, node, server, resource;

  if (argc != 1)
    return enif_make_badarg(env);

  if (!(enif_inspect_iolist_as_binary(env, argv[0], &input)))
    return enif_make_badarg(env);

  if (input.size == 0)
    return enif_make_atom(env, "error");

  enif_alloc_binary(0, &node);
  enif_alloc_binary(0, &server);
  enif_alloc_binary(0, &resource);

  while (pos < input.size) {

    if (state == STATE_NODE) {
      chr = input.data[pos];
      if (chr == '/')
	state = STATE_SERVER;
      if (chr == '@') {
	if (pos == 0 || pos+1 == input.size)
	  return make_error(env, &input, &node, &server, &resource);
	enif_realloc_binary(&node, pos);
	memcpy(node.data, input.data, pos);
	amp = ++pos;
	state = STATE_SERVER;
      }
    }

    if (state == STATE_SERVER) {
      chr = input.data[pos];
      if (chr == '@')
	return make_error(env, &input, &node, &server, &resource);
      if (chr == '/') {
	if (pos == 0 || pos+1 == input.size || pos == amp)
	  return make_error(env, &input, &node, &server, &resource);
	enif_realloc_binary(&server, pos - amp);
	memcpy(server.data, input.data + amp, pos - amp);
	slash = ++pos;
	state = STATE_RESOURCE;
      }
    }

    if (state == STATE_RESOURCE)
      break;

    pos++;
  }

  switch (state) {
  case STATE_NODE:
    enif_realloc_binary(&server, input.size);
    memcpy(server.data, input.data, input.size);
    break;
  case STATE_SERVER:
    enif_realloc_binary(&server, input.size - amp);
    memcpy(server.data, input.data + amp, input.size - amp);
    break;
  case STATE_RESOURCE:
    enif_realloc_binary(&resource, input.size - slash);
    memcpy(resource.data, input.data + slash, input.size - slash);
    break;
  }

  return enif_make_tuple3(env,
			  enif_make_binary(env, &node),
			  enif_make_binary(env, &server),
			  enif_make_binary(env, &resource));
}

static ErlNifFunc nif_funcs[] =
  {
    {"string_to_usr", 1, string_to_usr}
  };

ERL_NIF_INIT(jlib, nif_funcs, load, NULL, NULL, NULL)
