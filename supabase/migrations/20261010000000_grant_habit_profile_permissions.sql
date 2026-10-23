-- Grant permissions and set security definer on habit profiling functions
ALTER FUNCTION public.refresh_habit_profile(uuid) SECURITY DEFINER;
ALTER FUNCTION public.tag_transactions(uuid) SECURITY DEFINER;
ALTER FUNCTION public.compute_habit_profile(uuid) SECURITY DEFINER;
ALTER FUNCTION public.assign_archetype(jsonb) SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION public.refresh_habit_profile(uuid) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.tag_transactions(uuid) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.compute_habit_profile(uuid) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.assign_archetype(jsonb) TO authenticated, anon;

GRANT ALL ON TABLE public.user_habit_profile TO authenticated, service_role;
