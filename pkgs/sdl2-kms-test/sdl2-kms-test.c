/*
 * sdl2-kms-test: minimal SDL2 + OpenGL ES 2 test for KMS/DRM without a
 * display server.
 *
 *   SDL_VIDEODRIVER=kmsdrm sdl2-kms-test [seconds]
 *
 * Prints the SDL video driver and GL strings, draws a rotating triangle,
 * a square under each touch point, and prints the frame rate once per
 * second. Exits after `seconds` (default 20), on Escape/q, or when four
 * fingers touch the screen at once.
 */
#include <SDL.h>
#include <SDL_opengles2.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#define MAX_FINGERS 10

static const char *vertex_src =
	"attribute vec2 pos;\n"
	"attribute vec3 col;\n"
	"uniform float angle;\n"
	"uniform vec2 scale;\n"
	"varying vec3 v_col;\n"
	"void main() {\n"
	"  float c = cos(angle), s = sin(angle);\n"
	"  vec2 p = vec2(c * pos.x - s * pos.y, s * pos.x + c * pos.y);\n"
	"  gl_Position = vec4(p * scale, 0.0, 1.0);\n"
	"  v_col = col;\n"
	"}\n";

static const char *fragment_src =
	"precision mediump float;\n"
	"varying vec3 v_col;\n"
	"void main() { gl_FragColor = vec4(v_col, 1.0); }\n";

static GLuint compile(GLenum type, const char *src)
{
	GLuint s = glCreateShader(type);
	GLint ok;

	glShaderSource(s, 1, &src, NULL);
	glCompileShader(s);
	glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
	if (!ok) {
		char log[512];

		glGetShaderInfoLog(s, sizeof(log), NULL, log);
		fprintf(stderr, "shader error: %s\n", log);
		exit(1);
	}
	return s;
}

struct finger {
	SDL_FingerID id;
	float x, y;
	int active;
};

int main(int argc, char **argv)
{
	int seconds = argc > 1 ? atoi(argv[1]) : 20;
	struct finger fingers[MAX_FINGERS] = { 0 };
	SDL_Window *win;
	SDL_GLContext ctx;
	SDL_DisplayMode mode;
	GLuint prog;
	int w, h, quit = 0;
	Uint32 start, last_report;
	unsigned frames = 0, total_frames = 0;

	if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS) != 0) {
		fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
		return 1;
	}
	printf("SDL video driver: %s\n", SDL_GetCurrentVideoDriver());
	if (SDL_GetCurrentDisplayMode(0, &mode) == 0)
		printf("Display mode: %dx%d @ %d Hz\n", mode.w, mode.h, mode.refresh_rate);

	SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_ES);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 2);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 0);

	win = SDL_CreateWindow("sdl2-kms-test", 0, 0, 0, 0,
			       SDL_WINDOW_OPENGL | SDL_WINDOW_FULLSCREEN_DESKTOP);
	if (!win) {
		fprintf(stderr, "SDL_CreateWindow: %s\n", SDL_GetError());
		return 1;
	}
	ctx = SDL_GL_CreateContext(win);
	if (!ctx) {
		fprintf(stderr, "SDL_GL_CreateContext: %s\n", SDL_GetError());
		return 1;
	}
	SDL_GL_SetSwapInterval(1);
	SDL_GL_GetDrawableSize(win, &w, &h);

	printf("Drawable: %dx%d\n", w, h);
	printf("GL_VENDOR:   %s\n", glGetString(GL_VENDOR));
	printf("GL_RENDERER: %s\n", glGetString(GL_RENDERER));
	printf("GL_VERSION:  %s\n", glGetString(GL_VERSION));
	printf("GLSL:        %s\n", glGetString(GL_SHADING_LANGUAGE_VERSION));
	fflush(stdout);

	prog = glCreateProgram();
	glAttachShader(prog, compile(GL_VERTEX_SHADER, vertex_src));
	glAttachShader(prog, compile(GL_FRAGMENT_SHADER, fragment_src));
	glBindAttribLocation(prog, 0, "pos");
	glBindAttribLocation(prog, 1, "col");
	glLinkProgram(prog);
	glUseProgram(prog);

	static const GLfloat tri[] = {
		0.0f, 0.8f, 1, 0, 0,
		-0.7f, -0.4f, 0, 1, 0,
		0.7f, -0.4f, 0, 0, 1,
	};
	glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 5 * sizeof(GLfloat), tri);
	glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 5 * sizeof(GLfloat), tri + 2);
	glEnableVertexAttribArray(0);
	glEnableVertexAttribArray(1);

	GLint u_angle = glGetUniformLocation(prog, "angle");
	GLint u_scale = glGetUniformLocation(prog, "scale");

	start = last_report = SDL_GetTicks();
	while (!quit) {
		SDL_Event ev;
		Uint32 now = SDL_GetTicks();
		int n_active = 0;

		while (SDL_PollEvent(&ev)) {
			switch (ev.type) {
			case SDL_QUIT:
				quit = 1;
				break;
			case SDL_KEYDOWN:
				if (ev.key.keysym.sym == SDLK_ESCAPE || ev.key.keysym.sym == SDLK_q)
					quit = 1;
				break;
			case SDL_FINGERDOWN:
			case SDL_FINGERMOTION:
			case SDL_FINGERUP:
				for (int i = 0; i < MAX_FINGERS; i++) {
					struct finger *f = &fingers[i];

					if ((f->active && f->id == ev.tfinger.fingerId) ||
					    (!f->active && ev.type == SDL_FINGERDOWN)) {
						f->id = ev.tfinger.fingerId;
						f->x = ev.tfinger.x;
						f->y = ev.tfinger.y;
						f->active = ev.type != SDL_FINGERUP;
						if (ev.type == SDL_FINGERDOWN)
							printf("finger down: x=%.3f y=%.3f\n", f->x, f->y);
						break;
					}
				}
				break;
			}
		}

		/*
		 * Under Wayland the size is only known after the compositor's
		 * configure event (the drawable is 1x1 right after creation),
		 * and SDL doesn't update the viewport on resize.
		 */
		SDL_GL_GetDrawableSize(win, &w, &h);
		glViewport(0, 0, w, h);
		/* Keep the triangle round on the portrait screen */
		if (w < h)
			glUniform2f(u_scale, 1.0f, (float)w / h);
		else
			glUniform2f(u_scale, (float)h / w, 1.0f);

		glDisable(GL_SCISSOR_TEST);
		glClearColor(0.1f, 0.1f, 0.2f, 1.0f);
		glClear(GL_COLOR_BUFFER_BIT);

		glUniform1f(u_angle, (now - start) / 1000.0f);
		glDrawArrays(GL_TRIANGLES, 0, 3);

		/* Touch points: 80x80 px white squares, GL origin is bottom-left */
		glEnable(GL_SCISSOR_TEST);
		for (int i = 0; i < MAX_FINGERS; i++) {
			if (!fingers[i].active)
				continue;
			n_active++;
			glScissor((int)(fingers[i].x * w) - 40,
				  (int)((1.0f - fingers[i].y) * h) - 40, 80, 80);
			glClearColor(1, 1, 1, 1);
			glClear(GL_COLOR_BUFFER_BIT);
		}
		if (n_active >= 4)
			quit = 1;

		SDL_GL_SwapWindow(win);
		frames++;
		total_frames++;

		if (now - last_report >= 1000) {
			printf("%.1f fps\n", frames * 1000.0f / (now - last_report));
			fflush(stdout);
			frames = 0;
			last_report = now;
		}
		if (seconds > 0 && now - start >= (Uint32)seconds * 1000)
			quit = 1;
	}

	printf("%u frames in %.1f s\n", total_frames, (SDL_GetTicks() - start) / 1000.0f);
	SDL_GL_DeleteContext(ctx);
	SDL_DestroyWindow(win);
	SDL_Quit();
	return 0;
}
